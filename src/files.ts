import * as command from "@pulumi/command";
import { kubeconfig, talosconfig } from "./talos";

// ---------------------------------------------------------------------------
// Write talosconfig and kubeconfig to .talos/ for CLI access
// ---------------------------------------------------------------------------

new command.local.Command("write-talosconfig", {
	create: "mkdir -p .talos && cat > .talos/talosconfig",
	stdin: talosconfig.talosConfig,
	triggers: [talosconfig.talosConfig],
});

new command.local.Command("write-kubeconfig", {
	create: "mkdir -p .talos && cat > .talos/kubeconfig",
	stdin: kubeconfig.kubeconfigRaw,
	triggers: [kubeconfig.kubeconfigRaw],
});
