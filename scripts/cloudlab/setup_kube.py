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

    def kube_cluster_setup(self):
        self.environment_setup()
        join_command = self.init_kubernetes_on_main()
        self.join_workers_to_cluster(join_command)

if __name__ == "__main__":
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    kube_setup = KubeSetUp("./config.json")
    kube_setup.kube_cluster_setup()