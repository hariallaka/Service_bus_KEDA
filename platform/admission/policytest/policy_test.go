// Offline tests for ../keda-tenant-guardrails.yaml. Compiles every CEL
// expression in the policies with the same base libraries the Kubernetes API
// server uses for ValidatingAdmissionPolicy (cel-go standard + strings ext)
// and evaluates them against allowed and denied objects, including the
// manifests rendered by charts/keda-servicebus-consumer.
//
//	cd platform/admission/policytest && go test ./...
//
// Regenerate testdata/rendered-*.yaml with:
//
//	helm template app-1234-uc01-orders ../../../charts/keda-servicebus-consumer -f ../../../charts/keda-servicebus-consumer/values-tenant-a.yaml > testdata/rendered-tenant-a.yaml
//	helm template app-5678-uc02-billing ../../../charts/keda-servicebus-consumer -f ../../../charts/keda-servicebus-consumer/values-tenant-b.yaml > testdata/rendered-tenant-b.yaml
package policytest

import (
	"bytes"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common/types"
	"github.com/google/cel-go/common/types/ref"
	"github.com/google/cel-go/ext"
	"sigs.k8s.io/yaml"
)

type expr struct {
	Name              string `json:"name"`
	Expression        string `json:"expression"`
	Message           string `json:"message"`
	MessageExpression string `json:"messageExpression"`
}

type policy struct {
	Kind     string `json:"kind"`
	Metadata struct {
		Name string `json:"name"`
	} `json:"metadata"`
	Spec struct {
		Variables   []expr `json:"variables"`
		Validations []expr `json:"validations"`
	} `json:"spec"`
}

func splitDocs(t *testing.T, path string) []map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var out []map[string]any
	for _, d := range bytes.Split(raw, []byte("\n---")) {
		var m map[string]any
		if err := yaml.Unmarshal(d, &m); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		if m != nil {
			out = append(out, m)
		}
	}
	return out
}

func loadPolicies(t *testing.T) map[string]policy {
	t.Helper()
	out := map[string]policy{}
	for _, d := range splitDocs(t, "../keda-tenant-guardrails.yaml") {
		if d["kind"] != "ValidatingAdmissionPolicy" {
			continue
		}
		b, _ := yaml.Marshal(d)
		var p policy
		if err := yaml.Unmarshal(b, &p); err != nil {
			t.Fatal(err)
		}
		out[p.Metadata.Name] = p
	}
	return out
}

func newEnv(t *testing.T) *cel.Env {
	t.Helper()
	env, err := cel.NewEnv(
		cel.Variable("object", cel.DynType),
		cel.Variable("oldObject", cel.DynType),
		cel.Variable("namespaceObject", cel.DynType),
		cel.Variable("variables", cel.MapType(cel.StringType, cel.DynType)),
		ext.Strings(ext.StringsVersion(2)),
	)
	if err != nil {
		t.Fatal(err)
	}
	return env
}

func eval(t *testing.T, env *cel.Env, src string, act map[string]any) (ref.Val, error) {
	t.Helper()
	ast, iss := env.Compile(src)
	if iss.Err() != nil {
		t.Fatalf("compile %q: %v", src, iss.Err())
	}
	prg, err := env.Program(ast)
	if err != nil {
		t.Fatal(err)
	}
	v, _, err := prg.Eval(act)
	return v, err
}

// admit returns "" if allowed, otherwise the first failing rule's message.
// Evaluation errors deny, matching failurePolicy: Fail.
func admit(t *testing.T, p policy, obj, ns map[string]any) string {
	env := newEnv(t)
	vars := map[string]any{}
	act := map[string]any{"object": obj, "namespaceObject": ns, "variables": vars}
	for _, v := range p.Spec.Variables {
		val, err := eval(t, env, v.Expression, act)
		if err != nil {
			return fmt.Sprintf("variable %s error: %v", v.Name, err)
		}
		vars[v.Name] = val
	}
	for _, v := range p.Spec.Validations {
		val, err := eval(t, env, v.Expression, act)
		if err != nil {
			return fmt.Sprintf("error: %v", err)
		}
		if val != types.True {
			if v.MessageExpression != "" {
				m, err := eval(t, env, v.MessageExpression, act)
				if err != nil {
					t.Fatalf("messageExpression %q: %v", v.MessageExpression, err)
				}
				return m.Value().(string)
			}
			return v.Message
		}
	}
	return ""
}

func ns(name, tenant, clientID string) map[string]any {
	return map[string]any{"metadata": map[string]any{
		"name":        name,
		"labels":      map[string]any{"platform.io/tenant": tenant},
		"annotations": map[string]any{"platform.io/workload-identity-client-id": clientID},
	}}
}

var (
	nsA = ns("tenant-app-1234-uc01", "APP-1234-UC01", "00000000-0000-0000-0000-00000000000a")
	nsB = ns("tenant-app-5678-uc02", "APP-5678-UC02", "00000000-0000-0000-0000-00000000000b")
)

func rendered(t *testing.T, path, kind string) map[string]any {
	t.Helper()
	for _, d := range splitDocs(t, path) {
		if d["kind"] == kind {
			return d
		}
	}
	t.Fatalf("%s not found in %s", kind, path)
	return nil
}

func fromYAML(t *testing.T, s string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := yaml.Unmarshal([]byte(s), &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestRenderedChartIsAdmitted(t *testing.T) {
	p := loadPolicies(t)
	for _, c := range []struct {
		file string
		ns   map[string]any
	}{{"testdata/rendered-tenant-a.yaml", nsA}, {"testdata/rendered-tenant-b.yaml", nsB}} {
		if msg := admit(t, p["keda-tenant-triggerauthentication"], rendered(t, c.file, "TriggerAuthentication"), c.ns); msg != "" {
			t.Errorf("%s TriggerAuthentication denied: %s", c.file, msg)
		}
		if msg := admit(t, p["keda-tenant-scaling"], rendered(t, c.file, "ScaledObject"), c.ns); msg != "" {
			t.Errorf("%s ScaledObject denied: %s", c.file, msg)
		}
	}
}

func TestTriggerAuthenticationDenied(t *testing.T) {
	p := loadPolicies(t)["keda-tenant-triggerauthentication"]
	cases := map[string]struct {
		spec string
		ns   map[string]any
		want string
	}{
		"other tenant's identity": {`
spec:
  podIdentity: {provider: azure-workload, identityId: 00000000-0000-0000-0000-00000000000a}`, nsB, "onboarded identity"},
		"no identityId (would fall back to KEDA's own identity)": {`
spec:
  podIdentity: {provider: azure-workload}`, nsA, "onboarded identity"},
		"namespace without onboarding annotation": {`
spec:
  podIdentity: {provider: azure-workload, identityId: 00000000-0000-0000-0000-00000000000a}`,
			map[string]any{"metadata": map[string]any{"labels": map[string]any{"platform.io/tenant": "APP-1234-UC01"}}}, "none recorded"},
		"SAS connection string": {`
spec:
  secretTargetRef: [{parameter: connection, name: sb, key: conn}]`, nsA, "podIdentity.provider"},
		"SAS alongside pod identity": {`
spec:
  podIdentity: {provider: azure-workload, identityId: 00000000-0000-0000-0000-00000000000a}
  secretTargetRef: [{parameter: connection, name: sb, key: conn}]`, nsA, "Secret-based"},
		"cross-tenant override": {`
spec:
  podIdentity: {provider: azure-workload, identityId: 00000000-0000-0000-0000-00000000000a, identityTenantId: 99999999-0000-0000-0000-000000000000}`, nsA, "Cross-tenant"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			msg := admit(t, p, fromYAML(t, c.spec), c.ns)
			if !strings.Contains(msg, c.want) {
				t.Errorf("want denial containing %q, got %q", c.want, msg)
			}
		})
	}
}

func TestMalformedTenantLabelDenied(t *testing.T) {
	p := loadPolicies(t)["keda-tenant-scaling"]
	// Label "APP" would make the prefix q-app-, matching every tenant.
	obj := fromYAML(t, `
spec:
  maxReplicaCount: 10
  triggers:
    - type: azure-servicebus
      authenticationRef: {name: ta}
      metadata: {namespace: sb-daas, queueName: q-app-5678-uc02-orders}`)
	for _, label := range []string{"APP", "app-1234-uc01", "APP-1234-UC1"} {
		msg := admit(t, p, obj, ns("tenant-x", label, "00000000-0000-0000-0000-00000000000a"))
		if !strings.Contains(msg, "canonical tenant ID") {
			t.Errorf("label %q: want canonical-ID denial, got %q", label, msg)
		}
	}
}

func TestScaledObjectDenied(t *testing.T) {
	p := loadPolicies(t)["keda-tenant-scaling"]
	base := func(meta string, extra string) string {
		return `
spec:
  maxReplicaCount: 10
` + extra + `
  triggers:
    - type: azure-servicebus
      authenticationRef: {name: ta}
      metadata: ` + meta
	}
	cases := map[string]struct {
		obj  string
		want string
	}{
		"other tenant's queue":        {base(`{namespace: sb-daas, queueName: q-app-5678-uc02-orders}`, ""), "must target q-app-1234-uc01-"},
		"same app, other use case":    {base(`{namespace: sb-daas, queueName: q-app-1234-uc02-orders}`, ""), "must target q-app-1234-uc01-"},
		"longer app number prefix":    {base(`{namespace: sb-daas, queueName: q-app-12345-uc01-orders}`, ""), "must target q-app-1234-uc01-"},
		"topic without subscription":  {base(`{namespace: sb-daas, topicName: t-app-1234-uc01-events}`, ""), "must target"},
		"unapproved namespace":        {base(`{namespace: sb-rogue, queueName: q-app-1234-uc01-orders}`, ""), "must be one of sb-daas"},
		"FQDN instead of short name":  {base(`{namespace: sb-daas.servicebus.windows.net, queueName: q-app-1234-uc01-orders}`, ""), "short name"},
		"connection string from env":  {base(`{namespace: sb-daas, queueName: q-app-1234-uc01-orders, connectionFromEnv: SB_CONN}`, ""), "connection strings"},
		"regex across queues":         {base(`{namespace: sb-daas, queueName: "q-app-1234-uc01-.*", useRegex: "true"}`, ""), "useRegex"},
		"messageCount above cap":      {base(`{namespace: sb-daas, queueName: q-app-1234-uc01-orders, messageCount: "5000"}`, ""), "messageCount"},
		"messageCount not a number":   {base(`{namespace: sb-daas, queueName: q-app-1234-uc01-orders, messageCount: "lots"}`, ""), "error"},
		"replica cap exceeded":        {strings.Replace(base(`{namespace: sb-daas, queueName: q-app-1234-uc01-orders}`, ""), "maxReplicaCount: 10", "maxReplicaCount: 500", 1), "maxReplicaCount"},
		"min above max":               {base(`{namespace: sb-daas, queueName: q-app-1234-uc01-orders}`, "  minReplicaCount: 20"), "minReplicaCount"},
		"polling too aggressive":      {base(`{namespace: sb-daas, queueName: q-app-1234-uc01-orders}`, "  pollingInterval: 1"), "pollingInterval"},
		"max replicas left unbounded": {strings.Replace(base(`{namespace: sb-daas, queueName: q-app-1234-uc01-orders}`, ""), "maxReplicaCount: 10", "", 1), "maxReplicaCount"},
		"cluster trigger auth": {`
spec:
  maxReplicaCount: 10
  triggers:
    - type: azure-servicebus
      authenticationRef: {name: shared, kind: ClusterTriggerAuthentication}
      metadata: {namespace: sb-daas, queueName: q-app-1234-uc01-orders}`, "ClusterTriggerAuthentication"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			msg := admit(t, p, fromYAML(t, c.obj), nsA)
			if !strings.Contains(msg, c.want) {
				t.Errorf("want denial containing %q, got %q", c.want, msg)
			}
		})
	}
}
