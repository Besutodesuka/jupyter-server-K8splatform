// Package integration runs the controller against a real Kubernetes API server
// spun up by controller-runtime's envtest (no kubelet, no cluster required).
//
// Setup: install the API server binaries once with:
//
//	go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest
//	setup-envtest use 1.29 --bin-dir /usr/local/kubebuilder/bin
//	export KUBEBUILDER_ASSETS=/usr/local/kubebuilder/bin
//
// Run:
//
//	KUBEBUILDER_ASSETS=/usr/local/kubebuilder/bin go test ./integration/... -v
package integration_test

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	"github.com/sk09/lifecycle-controller/controller"
)

var (
	testEnv *envtest.Environment
	ctx     context.Context
	cancel  context.CancelFunc
)

func TestIntegration(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Lifecycle Controller Integration Suite")
}

var _ = BeforeSuite(func() {
	ctrl.SetLogger(zap.New(zap.WriteTo(GinkgoWriter), zap.UseDevMode(true)))
	ctx, cancel = context.WithCancel(context.Background())

	testEnv = &envtest.Environment{
		// No CRDs needed — we only use built-in Namespace and StatefulSet resources.
		CRDDirectoryPaths: []string{filepath.Join("..", "k8s")},
	}

	cfg, err := testEnv.Start()
	Expect(err).NotTo(HaveOccurred())
	Expect(cfg).NotTo(BeNil())

	scheme := runtime.NewScheme()
	Expect(corev1.AddToScheme(scheme)).To(Succeed())
	Expect(appsv1.AddToScheme(scheme)).To(Succeed())

	mgr, err := ctrl.NewManager(cfg, ctrl.Options{Scheme: scheme})
	Expect(err).NotTo(HaveOccurred())

	// Wire the reconciler in — time injection kept at default (real wall clock).
	err = (&controller.NamespaceReconciler{Client: mgr.GetClient()}).
		SetupWithManager(mgr)
	Expect(err).NotTo(HaveOccurred())

	// Store the manager client for test use.
	integrationClient = mgr.GetClient()

	go func() {
		defer GinkgoRecover()
		Expect(mgr.Start(ctx)).To(Succeed())
	}()
})

var _ = AfterSuite(func() {
	cancel()
	Expect(testEnv.Stop()).To(Succeed())
})

// integrationClient is set by BeforeSuite and used by the Describe blocks.
var integrationClient client.Client

// shortPoll is how often Eventually checks conditions in integration tests.
const shortPoll = 500 * time.Millisecond
