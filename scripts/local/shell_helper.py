import json
import os
import subprocess
from multiprocessing import Process
import argparse

'''
This script is used to set up remote nodes for a distributed system.
If you want to run this script, your ssh key shouldn't have a passphrase.
'''
class ShellHelper:
    def __init__(self, config):
        with open(config, 'r') as f:
            config = json.load(f)
        self.config = config

    def get_home_path(self, file_path):
        filename = os.path.basename(file_path)
        home_path = os.path.join(self.config["nodes_home"], filename)
        return home_path

    def scp_command(self, local_path, remote_path, node_ip, node_user):
        """
        Generate the scp command to copy a file to a remote node.
        """
        subprocess.run(
            ['ssh-keyscan', '-H', node_ip],
            stdout=open(os.path.expanduser('~/.ssh/known_hosts'), 'a'),
            check=True
        )

        command = [
            'scp', local_path,
            f'{node_user}@{node_ip}:{remote_path}'
        ]
        subprocess.run(command, check=True)

    def copy_files_to_nodes(self, file, mode=0):
        """
        Copy files to remote nodes.
        """
        config = self.config
        if os.path.exists(file):
            if os.name == "nt":
                # need to use dos2unix to convert the line endings
                subprocess.run(['dos2unix', file], check=True)
            for node in config["nodes"]:
                if mode == 1 and node == config["nodes"][0]:
                    # skip main node if worker_mode is enabled
                    continue
                if mode == 2 and node != config["nodes"][0]:
                    # skip worker nodes if main_mode is enabled
                    continue
                self.scp_command(file, config["nodes_home"], node, config["nodes_user"])
        else:
            print(f"File {file} does not exist.")
            exit(1)

    def execute_script(self, node_ip, node_user, file, args=[]):
        """
        Execute the script file on a remote node.
        """
        # print(f"[*] Executing script on node {node_number} ({node_ip})...")
        chmod_command = [
            'ssh', f'{node_user}@{node_ip}',
            'chmod', '+x', file
        ]
        subprocess.run(chmod_command, check=True)

        command = [
            'ssh', f'{node_user}@{node_ip}',
            '/bin/bash', file, *args
        ]

        result = subprocess.run(command, check=True, capture_output=True, text=True)
        return result.stdout.strip()

    def execute_parallel(self, file=None, mode=0, args=[]):
        config = self.config

        # execute the setup script on each node
        processes = []
        for i, node in enumerate(config["nodes"]):
            if mode == 1 and i == 0:
                # skip main node if worker_mode is enabled
                continue
            if mode == 2 and i != 0:
                # skip worker nodes if main_mode is enabled
                continue
            execute_args = (node, config["nodes_user"], file, args)
            p = Process(target=self.execute_script, args=execute_args)
            processes.append(p)
            p.start()

        for p in processes:
            p.join()
    
if __name__ == "__main__":
    # create the shell helper
    current_dir = os.path.dirname(os.path.abspath(__file__))
    config_path = os.path.join(current_dir, "./config.json")
    shell_helper = ShellHelper(config_path)

    # parse the command line arguments
    parser = argparse.ArgumentParser(description="Setup script for remote nodes.")
    parser.add_argument(
        "-f",
        type=str,
        help="The file to copy and execute on the remote nodes."
    )
    parser.add_argument(
        "-m",
        type=int,
        choices=[0, 1, 2],
        help="0: all nodes, 1: execute on worker nodes only, 2: execute on main node only"
    )
    args = parser.parse_args()
    file = os.path.join(current_dir, args.f) if args.f else None
    mode = args.m

    if file is None:
        print("Please provide a file to copy and execute.")
        help_text = parser.format_help()
        print(help_text)
        exit(1)
    shell_helper.copy_files_to_nodes(file, mode)
    shell_helper.execute_parallel(shell_helper.get_home_path(file), mode)