k8s-file-importer
====

Overview
----
This tool can import local files into an existing Kubernetes PersistentVolumeClaim. It is designed to be able to operate without needing much additional software or services.

How it Works
----
The importer script launches a Pod that sleeps forever in a specified Namespace that binds to a specified PersistentVolumeClaim. It then will use `kubectl` to transfer any number of specified files or directories to the PersistentVolumeClaim's mount point, unsing one of the following methods:
- By using `kubectl cp` to move the files and directories directly.
- By using `tar` with `kubectl exec` to move the files and directories in a compressed archive (needed for irregular filenames or faster transfers).

Requirements
----
The only fundamental requirement is that the image used for the Pod must contain the `sleep` command. If using the option to transfer files in an archive, then `tar` must also be present in the image.

