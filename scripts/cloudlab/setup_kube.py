import re
import os
from shell_helper import ShellHelper

class KubeSetUp:
    def __init__(self, config_path):
        self.shell_helper = ShellHelper(config_path)
        self.current_dir = os.path.dirname(os.path.abspath(__file__))

    def environment_setup(self):
        print("[*] Setting up Kubernetes environment on all nodes...")
        setup_script_path = "./kube.sh"
        self.shell_helper.copy_files_to_nodes(setup_script_path, mode=0)
        self.shell_helper.execute_parallel(self.shell_helper.get_home_path(setup_script_path), mode=0)

    def init_kubernetes_on_main(self):
        print("[*] Initializing Kubernetes on main node...")
        config = self.shell_helper.config
        main_node = config["nodes"][0]
        init_script_path = "./init_kube.sh"
        self.shell_helper.copy_files_to_nodes(init_script_path, mode=2)
        # advertise the API server on the main node's internal LAN IP so the
        # generated join command targets 10.0.0.x, not the public CloudLab IP
        result = self.shell_helper.execute_script(main_node, config["nodes_user"], self.shell_helper.get_home_path(init_script_path), args=[main_node])
        match = re.search(r"(kubeadm join\s[\s\S]+?)(?:\n\n|\Z)", str(result))
        join_command = ""
        if match:
            join_command = match.group(1)
        else:
            print("[!] Failed to extract join command from kubeadm output.")
            exit(1)
        print(join_command)
        return join_command

    def join_workers_to_cluster(self, join_command):
        print("[*] Joining worker nodes to the Kubernetes cluster...")
        join_kube_path = "./join_kube.sh"
        after_join_path = "./after_join.sh"
        # write join command to file
        with open(join_kube_path, "w") as f:
            f.write(f"sudo {join_command}")

        self.shell_helper.copy_files_to_nodes(join_kube_path, mode=1)
        self.shell_helper.execute_parallel(self.shell_helper.get_home_path(join_kube_path), mode=1)
        self.shell_helper.copy_files_to_nodes(after_join_path, mode=2)
        self.shell_helper.execute_parallel(self.shell_helper.get_home_path(after_join_path), mode=2)

    def enable_istio_metrics_on_main(self):
        # Install Istio control plane + Prometheus addon and turn on sidecar
        # auto-injection so the benchmark microservices export
        # istio_requests_total / istio_request_duration_milliseconds etc.
        # Runs on the main node only (it owns the kubeconfig from after_join.sh).
        # Gated by "enable_istio_metrics" in config.json (default off).
        print("[*] Enabling Istio metric collection on main node...")
        config = self.shell_helper.config
        istio_script_path = "./enable_istio_metrics.sh"
        self.shell_helper.copy_files_to_nodes(istio_script_path, mode=2)
        self.shell_helper.execute_script(
            config["nodes"][0],
            config["nodes_user"],
            self.shell_helper.get_home_path(istio_script_path),
        )

    def enable_audit_log_on_main(self):
        # kube-apiserver audit logging: write the audit policy and patch the
        # static-pod manifest on the control-plane node (nodes[0] hosts the
        # apiserver). Restarts the apiserver; the script blocks until it is
        # back and audit events are flowing.
        # Gated by "enable_audit_log" in config.json (default off).
        print("[*] Enabling K8s API audit logging on main node...")
        config = self.shell_helper.config
        audit_script_path = "./enable_audit_log.sh"
        self.shell_helper.copy_files_to_nodes(audit_script_path, mode=2)
        self.shell_helper.execute_script(
            config["nodes"][0],
            config["nodes_user"],
            self.shell_helper.get_home_path(audit_script_path),
        )

    def addons_setup(self):
        # All config-gated cluster add-ons. Factored out of kube_cluster_setup
        # so it can also run standalone against an already-initialized cluster
        # (`./bootstrap.sh addons` -> `setup_kube.py --addons-only`).
        # Audit before Istio: the apiserver restart finishes before istioctl
        # talks to it, and the Istio (re)install itself gets audited.
        if self.shell_helper.config.get("enable_audit_log", False):
            self.enable_audit_log_on_main()
        if self.shell_helper.config.get("enable_istio_metrics", False):
            self.enable_istio_metrics_on_main()

    def kube_cluster_setup(self):
        self.environment_setup()
        join_command = self.init_kubernetes_on_main()
        self.join_workers_to_cluster(join_command)
        self.addons_setup()

if __name__ == "__main__":
    import sys
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    kube_setup = KubeSetUp("./config.json")
    if "--addons-only" in sys.argv[1:]:
        kube_setup.addons_setup()
    else:
        kube_setup.kube_cluster_setup()