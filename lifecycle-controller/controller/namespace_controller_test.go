package controller_test

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	"github.com/sk09/lifecycle-controller/controller"
)

// ── helpers ──────────────────────────────────────────────────────────────────

func testScheme() *runtime.Scheme {
	s := runtime.NewScheme()
	_ = corev1.AddToScheme(s)
	_ = appsv1.AddToScheme(s)
	return s
}

func reconciler(objs ...client.Object) (*controller.NamespaceReconciler, client.Client) {
	c := fake.NewClientBuilder().
		WithScheme(testScheme()).
		WithObjects(objs...).
		Build()
	return &controller.NamespaceReconciler{Client: c}, c
}

func req(name string) ctrl.Request {
	return ctrl.Request{NamespacedName: types.NamespacedName{Name: name}}
}

// studentNS builds a Namespace tagged as a student environment.
func studentNS(name string, extraLabels map[string]string) *corev1.Namespace {
	labels := map[string]string{"platform": "jupyter-student"}
	for k, v := range extraLabels {
		labels[k] = v
	}
	return &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: name, Labels: labels}}
}

// sts builds a StatefulSet with the given replica count in the given namespace.
func sts(namespace, name string, replicas int32) *appsv1.StatefulSet {
	r := replicas
	return &appsv1.StatefulSet{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace},
		Spec:       appsv1.StatefulSetSpec{Replicas: &r},
	}
}

func pastDate() string  { return "2020-01-01" }
func futureDate() string { return "2099-12-31" }
func yesterday() string  { return time.Now().AddDate(0, 0, -1).Format("2006-01-02") }

// ── Tests ─────────────────────────────────────────────────────────────────────

// 1. Namespace deleted between enqueue and reconcile — should not error.
func TestReconcile_NamespaceNotFound(t *testing.T) {
	r, _ := reconciler() // empty cluster
	result, err := r.Reconcile(context.Background(), req("student-999"))

	assert.NoError(t, err)
	assert.Equal(t, ctrl.Result{}, result)
}

// 2. Namespace without platform=jupyter-student label — controller ignores it.
func TestReconcile_NonStudentNamespace(t *testing.T) {
	ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
		Name:   "kube-system",
		Labels: map[string]string{"kubernetes.io/metadata.name": "kube-system"},
	}}
	r, _ := reconciler(ns)
	result, err := r.Reconcile(context.Background(), req("kube-system"))

	assert.NoError(t, err)
	assert.Equal(t, ctrl.Result{}, result)
}

// 3. Student namespace with no expires-at label — requeue with 1-hour heartbeat.
func TestReconcile_MissingExpiresAt(t *testing.T) {
	ns := studentNS("student-001", nil) // no expires-at
	r, _ := reconciler(ns)
	result, err := r.Reconcile(context.Background(), req("student-001"))

	assert.NoError(t, err)
	assert.Equal(t, time.Hour, result.RequeueAfter)
}

// 4. Student namespace with malformed expires-at — logs error, does not retry.
func TestReconcile_MalformedExpiresAt(t *testing.T) {
	ns := studentNS("student-002", map[string]string{"expires-at": "not-a-date"})
	r, _ := reconciler(ns)
	result, err := r.Reconcile(context.Background(), req("student-002"))

	assert.NoError(t, err)
	assert.Equal(t, ctrl.Result{}, result) // no retry for bad label
}

// 5. Active namespace with far future expiry — requeues in at most 1 hour.
func TestReconcile_ActiveNamespace_FarExpiry(t *testing.T) {
	ns := studentNS("student-003", map[string]string{"expires-at": futureDate()})
	r, _ := reconciler(ns)
	result, err := r.Reconcile(context.Background(), req("student-003"))

	assert.NoError(t, err)
	assert.Equal(t, time.Hour, result.RequeueAfter, "should requeue at heartbeat interval for far expiry")
}

// 6. Active namespace expiring soon (within 1 hour) — requeues in less than 1 hour.
// We inject a fixed clock set to 30 minutes before the expiry threshold so the
// test is deterministic regardless of wall-clock time.
func TestReconcile_ActiveNamespace_NearExpiry(t *testing.T) {
	expiryDate := "2025-08-31"
	expiresAt, _ := time.Parse("2006-01-02", expiryDate)
	threshold := expiresAt.Add(24 * time.Hour)                     // 2025-09-01 00:00 UTC
	fakeNow := threshold.Add(-30 * time.Minute)                    // 30 min before threshold

	ns := studentNS("student-004", map[string]string{"expires-at": expiryDate})
	c := fake.NewClientBuilder().WithScheme(testScheme()).WithObjects(ns).Build()
	r := &controller.NamespaceReconciler{Client: c, Now: func() time.Time { return fakeNow }}

	result, err := r.Reconcile(context.Background(), req("student-004"))

	assert.NoError(t, err)
	assert.Less(t, result.RequeueAfter, time.Hour,
		"should requeue before heartbeat when threshold is within 1h")
	assert.InDelta(t, 30*time.Minute, result.RequeueAfter, float64(time.Second),
		"should requeue in approximately 30 minutes")
}

// 7. Already-suspended namespace — skips all patches, requeues heartbeat.
func TestReconcile_AlreadySuspended(t *testing.T) {
	ns := studentNS("student-005", map[string]string{
		"expires-at":       pastDate(),
		"lifecycle-status": "suspended",
	})
	s := sts("student-005", "jupyter-005", 0)
	r, c := reconciler(ns, s)
	result, err := r.Reconcile(context.Background(), req("student-005"))

	assert.NoError(t, err)
	assert.Equal(t, time.Hour, result.RequeueAfter)

	// StatefulSet must remain untouched (no second patch)
	var gotSts appsv1.StatefulSet
	require.NoError(t, c.Get(context.Background(), types.NamespacedName{
		Namespace: "student-005", Name: "jupyter-005",
	}, &gotSts))
	assert.Equal(t, int32(0), *gotSts.Spec.Replicas)
}

// 8. Expired namespace — StatefulSet scaled to 0, namespace labeled suspended.
func TestReconcile_ExpiredNamespace_SuspendsStatefulSet(t *testing.T) {
	ns := studentNS("student-006", map[string]string{"expires-at": pastDate()})
	s := sts("student-006", "jupyter-006", 1)
	r, c := reconciler(ns, s)

	result, err := r.Reconcile(context.Background(), req("student-006"))
	require.NoError(t, err)
	assert.Equal(t, time.Hour, result.RequeueAfter)

	// StatefulSet must be scaled to 0
	var gotSts appsv1.StatefulSet
	require.NoError(t, c.Get(context.Background(), types.NamespacedName{
		Namespace: "student-006", Name: "jupyter-006",
	}, &gotSts))
	assert.Equal(t, int32(0), *gotSts.Spec.Replicas, "StatefulSet should be scaled to 0")

	// Namespace must carry suspension labels
	var gotNs corev1.Namespace
	require.NoError(t, c.Get(context.Background(), types.NamespacedName{Name: "student-006"}, &gotNs))
	assert.Equal(t, "suspended", gotNs.Labels["lifecycle-status"])
	assert.Equal(t, time.Now().Format("2006-01-02"), gotNs.Labels["suspended-at"])
}

// 9. Expired namespace where StatefulSet is already at 0 — idempotent, no double-patch.
func TestReconcile_ExpiredNamespace_AlreadyAtZeroReplicas(t *testing.T) {
	ns := studentNS("student-007", map[string]string{"expires-at": pastDate()})
	s := sts("student-007", "jupyter-007", 0) // already 0
	r, c := reconciler(ns, s)

	_, err := r.Reconcile(context.Background(), req("student-007"))
	require.NoError(t, err)

	// Namespace still gets the suspended label even if sts was already at 0
	var gotNs corev1.Namespace
	require.NoError(t, c.Get(context.Background(), types.NamespacedName{Name: "student-007"}, &gotNs))
	assert.Equal(t, "suspended", gotNs.Labels["lifecycle-status"])
}

// 10. Expired namespace with multiple StatefulSets — all are scaled to 0.
func TestReconcile_ExpiredNamespace_MultipleStatefulSets(t *testing.T) {
	ns := studentNS("student-008", map[string]string{"expires-at": pastDate()})
	s1 := sts("student-008", "jupyter-008", 1)
	s2 := sts("student-008", "sidecar-008", 2) // hypothetical second workload
	r, c := reconciler(ns, s1, s2)

	_, err := r.Reconcile(context.Background(), req("student-008"))
	require.NoError(t, err)

	for _, name := range []string{"jupyter-008", "sidecar-008"} {
		var got appsv1.StatefulSet
		require.NoError(t, c.Get(context.Background(), types.NamespacedName{
			Namespace: "student-008", Name: name,
		}, &got))
		assert.Equal(t, int32(0), *got.Spec.Replicas, "all StatefulSets should be suspended: %s", name)
	}
}

// 11. Expired namespace with no StatefulSets — namespace is still labeled suspended.
func TestReconcile_ExpiredNamespace_NoStatefulSets(t *testing.T) {
	ns := studentNS("student-009", map[string]string{"expires-at": pastDate()})
	r, c := reconciler(ns) // no StatefulSet

	_, err := r.Reconcile(context.Background(), req("student-009"))
	require.NoError(t, err)

	var gotNs corev1.Namespace
	require.NoError(t, c.Get(context.Background(), types.NamespacedName{Name: "student-009"}, &gotNs))
	assert.Equal(t, "suspended", gotNs.Labels["lifecycle-status"])
}

// 12. expires-at = yesterday → just past the threshold → triggers suspension.
func TestReconcile_ExpiredNamespace_Yesterday(t *testing.T) {
	ns := studentNS("student-010", map[string]string{"expires-at": yesterday()})
	s := sts("student-010", "jupyter-010", 1)
	r, c := reconciler(ns, s)

	_, err := r.Reconcile(context.Background(), req("student-010"))
	require.NoError(t, err)

	var gotSts appsv1.StatefulSet
	require.NoError(t, c.Get(context.Background(), types.NamespacedName{
		Namespace: "student-010", Name: "jupyter-010",
	}, &gotSts))
	assert.Equal(t, int32(0), *gotSts.Spec.Replicas,
		"namespace that expired yesterday should be suspended")
}
