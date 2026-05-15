package controller

import (
	"context"
	"fmt"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
)

const (
	labelPlatform        = "platform"
	labelExpiresAt       = "expires-at"
	labelLifecycleStatus = "lifecycle-status"
	labelSuspendedAt     = "suspended-at"
	platformValue        = "jupyter-student"
	statusSuspended      = "suspended"
	dateFormat           = "2006-01-02"
	// heartbeat is the maximum interval between reconcile checks for active namespaces.
	// The watch fires immediately on any label change, so this is just a safety net.
	heartbeat = 1 * time.Hour
)

// NamespaceReconciler watches student Namespaces and suspends those past their expires-at date.
type NamespaceReconciler struct {
	client.Client
	// Now returns the current time. Defaults to time.Now; override in tests.
	Now func() time.Time
}

func (r *NamespaceReconciler) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

func (r *NamespaceReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := ctrl.LoggerFrom(ctx)

	var ns corev1.Namespace
	if err := r.Get(ctx, req.NamespacedName, &ns); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	if ns.Labels[labelPlatform] != platformValue {
		return ctrl.Result{}, nil
	}

	expiresAtStr, ok := ns.Labels[labelExpiresAt]
	if !ok {
		log.Info("no expires-at label, skipping", "namespace", ns.Name)
		return ctrl.Result{RequeueAfter: heartbeat}, nil
	}

	expiresAt, err := time.Parse(dateFormat, expiresAtStr)
	if err != nil {
		log.Error(err, "invalid expires-at label format (want YYYY-MM-DD)", "value", expiresAtStr)
		return ctrl.Result{}, nil // don't retry malformed label
	}

	// "expires-at: 2025-08-31" means active through that full day; suspend from the next day onward.
	threshold := expiresAt.Add(24 * time.Hour)
	now := r.now()

	if now.Before(threshold) {
		requeueIn := threshold.Sub(now)
		if requeueIn > heartbeat {
			requeueIn = heartbeat
		}
		log.Info("namespace active", "namespace", ns.Name, "expires-at", expiresAtStr, "requeue-in", requeueIn)
		return ctrl.Result{RequeueAfter: requeueIn}, nil
	}

	// Already suspended — nothing more to do.
	if ns.Labels[labelLifecycleStatus] == statusSuspended {
		return ctrl.Result{RequeueAfter: heartbeat}, nil
	}

	// Expired — scale every StatefulSet in this namespace to 0 (soft-delete).
	var stsList appsv1.StatefulSetList
	if err := r.List(ctx, &stsList, client.InNamespace(ns.Name)); err != nil {
		return ctrl.Result{}, fmt.Errorf("listing StatefulSets in %s: %w", ns.Name, err)
	}

	zero := int32(0)
	for i := range stsList.Items {
		sts := &stsList.Items[i]
		if sts.Spec.Replicas != nil && *sts.Spec.Replicas == 0 {
			continue
		}
		log.Info("scaling StatefulSet to 0", "namespace", ns.Name, "statefulset", sts.Name)
		patch := client.MergeFrom(sts.DeepCopy())
		sts.Spec.Replicas = &zero
		if err := r.Patch(ctx, sts, patch); err != nil {
			return ctrl.Result{}, fmt.Errorf("patching StatefulSet %s/%s: %w", ns.Name, sts.Name, err)
		}
	}

	// Mark namespace suspended so subsequent reconciles are cheap.
	today := now.Format(dateFormat)
	nsPatch := client.MergeFrom(ns.DeepCopy())
	ns.Labels[labelLifecycleStatus] = statusSuspended
	ns.Labels[labelSuspendedAt] = today
	if err := r.Patch(ctx, &ns, nsPatch); err != nil {
		return ctrl.Result{}, fmt.Errorf("labeling namespace %s: %w", ns.Name, err)
	}

	log.Info("namespace suspended", "namespace", ns.Name, "suspended-at", today)
	return ctrl.Result{RequeueAfter: heartbeat}, nil
}

func (r *NamespaceReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&corev1.Namespace{}).
		// Only enqueue namespaces tagged as student environments — ignore system namespaces.
		WithEventFilter(predicate.NewPredicateFuncs(func(obj client.Object) bool {
			return obj.GetLabels()[labelPlatform] == platformValue
		})).
		Complete(r)
}
