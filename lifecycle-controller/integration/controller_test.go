package integration_test

import (
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// ── helpers ───────────────────────────────────────────────────────────────────

func makeNamespace(name string, labels map[string]string) *corev1.Namespace {
	l := map[string]string{"platform": "jupyter-student"}
	for k, v := range labels {
		l[k] = v
	}
	return &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: name, Labels: l}}
}

func makeStatefulSet(namespace, name string, replicas int32) *appsv1.StatefulSet {
	r := replicas
	return &appsv1.StatefulSet{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace},
		Spec: appsv1.StatefulSetSpec{
			Replicas:    &r,
			ServiceName: name,
			Selector:    &metav1.LabelSelector{MatchLabels: map[string]string{"app": name}},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"app": name}},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{{
						Name:  "app",
						Image: "busybox",
						Resources: corev1.ResourceRequirements{
							Requests: corev1.ResourceList{
								corev1.ResourceCPU:    resource.MustParse("10m"),
								corev1.ResourceMemory: resource.MustParse("16Mi"),
							},
						},
					}},
				},
			},
		},
	}
}

func getNS(name string) *corev1.Namespace {
	ns := &corev1.Namespace{}
	Expect(integrationClient.Get(ctx, types.NamespacedName{Name: name}, ns)).To(Succeed())
	return ns
}

func getSTS(namespace, name string) *appsv1.StatefulSet {
	sts := &appsv1.StatefulSet{}
	Expect(integrationClient.Get(ctx, types.NamespacedName{Namespace: namespace, Name: name}, sts)).To(Succeed())
	return sts
}

// ── Test specs ────────────────────────────────────────────────────────────────

var _ = Describe("NamespaceReconciler", func() {

	Context("when a student namespace has a past expires-at date", func() {
		const nsName = "it-student-001"

		BeforeEach(func() {
			ns := makeNamespace(nsName, map[string]string{
				"expires-at": "2020-01-01",
				"semester":   "2019-fall",
			})
			Expect(integrationClient.Create(ctx, ns)).To(Succeed())

			sts := makeStatefulSet(nsName, "jupyter-001", 1)
			Expect(integrationClient.Create(ctx, sts)).To(Succeed())
		})

		AfterEach(func() {
			// Clean up so each test starts fresh.
			_ = integrationClient.Delete(ctx, &appsv1.StatefulSet{
				ObjectMeta: metav1.ObjectMeta{Name: "jupyter-001", Namespace: nsName},
			})
			_ = integrationClient.Delete(ctx, &corev1.Namespace{
				ObjectMeta: metav1.ObjectMeta{Name: nsName},
			})
		})

		It("scales the StatefulSet to 0 replicas", func() {
			Eventually(func() int32 {
				sts := getSTS(nsName, "jupyter-001")
				if sts.Spec.Replicas == nil {
					return -1
				}
				return *sts.Spec.Replicas
			}, 10*time.Second, shortPoll).Should(Equal(int32(0)))
		})

		It("labels the namespace lifecycle-status=suspended", func() {
			Eventually(func() string {
				return getNS(nsName).Labels["lifecycle-status"]
			}, 10*time.Second, shortPoll).Should(Equal("suspended"))
		})

		It("stamps suspended-at with today's date", func() {
			today := time.Now().Format("2006-01-02")
			Eventually(func() string {
				return getNS(nsName).Labels["suspended-at"]
			}, 10*time.Second, shortPoll).Should(Equal(today))
		})
	})

	Context("when a student namespace has a future expires-at date", func() {
		const nsName = "it-student-002"

		BeforeEach(func() {
			ns := makeNamespace(nsName, map[string]string{"expires-at": "2099-12-31"})
			Expect(integrationClient.Create(ctx, ns)).To(Succeed())

			sts := makeStatefulSet(nsName, "jupyter-002", 1)
			Expect(integrationClient.Create(ctx, sts)).To(Succeed())
		})

		AfterEach(func() {
			_ = integrationClient.Delete(ctx, &appsv1.StatefulSet{
				ObjectMeta: metav1.ObjectMeta{Name: "jupyter-002", Namespace: nsName},
			})
			_ = integrationClient.Delete(ctx, &corev1.Namespace{
				ObjectMeta: metav1.ObjectMeta{Name: nsName},
			})
		})

		It("does NOT scale the StatefulSet to 0", func() {
			// Give the controller time to reconcile; replicas should stay at 1.
			Consistently(func() int32 {
				sts := getSTS(nsName, "jupyter-002")
				if sts.Spec.Replicas == nil {
					return -1
				}
				return *sts.Spec.Replicas
			}, 3*time.Second, shortPoll).Should(Equal(int32(1)))
		})

		It("does NOT label the namespace as suspended", func() {
			Consistently(func() string {
				return getNS(nsName).Labels["lifecycle-status"]
			}, 3*time.Second, shortPoll).Should(BeEmpty())
		})
	})

	Context("when a student namespace is already suspended", func() {
		const nsName = "it-student-003"

		BeforeEach(func() {
			ns := makeNamespace(nsName, map[string]string{
				"expires-at":       "2020-01-01",
				"lifecycle-status": "suspended",
				"suspended-at":     "2020-01-02",
			})
			Expect(integrationClient.Create(ctx, ns)).To(Succeed())

			sts := makeStatefulSet(nsName, "jupyter-003", 0)
			Expect(integrationClient.Create(ctx, sts)).To(Succeed())
		})

		AfterEach(func() {
			_ = integrationClient.Delete(ctx, &appsv1.StatefulSet{
				ObjectMeta: metav1.ObjectMeta{Name: "jupyter-003", Namespace: nsName},
			})
			_ = integrationClient.Delete(ctx, &corev1.Namespace{
				ObjectMeta: metav1.ObjectMeta{Name: nsName},
			})
		})

		It("leaves the StatefulSet at 0 and does not re-patch", func() {
			// The controller should not overwrite the existing suspended-at label.
			Consistently(func() string {
				return getNS(nsName).Labels["suspended-at"]
			}, 3*time.Second, shortPoll).Should(Equal("2020-01-02"))
		})
	})

	Context("when a namespace has no platform=jupyter-student label", func() {
		const nsName = "it-other-ns"

		BeforeEach(func() {
			ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
				Name:   nsName,
				Labels: map[string]string{"purpose": "other"},
			}}
			Expect(integrationClient.Create(ctx, ns)).To(Succeed())
		})

		AfterEach(func() {
			_ = integrationClient.Delete(ctx, &corev1.Namespace{
				ObjectMeta: metav1.ObjectMeta{Name: nsName},
			})
		})

		It("ignores the namespace entirely", func() {
			Consistently(func() string {
				ns := &corev1.Namespace{}
				_ = integrationClient.Get(ctx, types.NamespacedName{Name: nsName}, ns)
				return ns.Labels["lifecycle-status"]
			}, 3*time.Second, shortPoll).Should(BeEmpty())
		})
	})

	Context("when an expired namespace has no StatefulSets", func() {
		const nsName = "it-student-004"

		BeforeEach(func() {
			ns := makeNamespace(nsName, map[string]string{"expires-at": "2020-01-01"})
			Expect(integrationClient.Create(ctx, ns)).To(Succeed())
			// No StatefulSet created.
		})

		AfterEach(func() {
			_ = integrationClient.Delete(ctx, &corev1.Namespace{
				ObjectMeta: metav1.ObjectMeta{Name: nsName},
			})
		})

		It("still labels the namespace as suspended", func() {
			Eventually(func() string {
				return getNS(nsName).Labels["lifecycle-status"]
			}, 10*time.Second, shortPoll).Should(Equal("suspended"))
		})
	})

	Context("reconciliation is idempotent", func() {
		const nsName = "it-student-005"

		BeforeEach(func() {
			ns := makeNamespace(nsName, map[string]string{"expires-at": "2020-01-01"})
			Expect(integrationClient.Create(ctx, ns)).To(Succeed())

			sts := makeStatefulSet(nsName, "jupyter-005", 1)
			Expect(integrationClient.Create(ctx, sts)).To(Succeed())
		})

		AfterEach(func() {
			_ = integrationClient.Delete(ctx, &appsv1.StatefulSet{
				ObjectMeta: metav1.ObjectMeta{Name: "jupyter-005", Namespace: nsName},
			})
			_ = integrationClient.Delete(ctx, &corev1.Namespace{
				ObjectMeta: metav1.ObjectMeta{Name: nsName},
			})
		})

		It("can reconcile repeatedly without error", func() {
			// Wait for first suspension.
			Eventually(func() string {
				return getNS(nsName).Labels["lifecycle-status"]
			}, 10*time.Second, shortPoll).Should(Equal("suspended"))

			// Trigger a label update to force re-reconcile.
			patch := client.MergeFrom(getNS(nsName).DeepCopy())
			ns := getNS(nsName)
			ns.Labels["test-requeue"] = "yes"
			Expect(integrationClient.Patch(ctx, ns, patch)).To(Succeed())

			// Status must remain suspended, not flap.
			Consistently(func() string {
				return getNS(nsName).Labels["lifecycle-status"]
			}, 3*time.Second, shortPoll).Should(Equal("suspended"))
		})
	})
})
