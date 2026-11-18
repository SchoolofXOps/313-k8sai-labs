| Path | Claim | StorageClass | Access mode | What is under it |
|---|---|---|---|---|
| s3 | spike02-s3-data | standard | ReadWriteOnce | an object store Pod reached over HTTP with the S3 protocol, keeping its data on this claim |
| nfs | spike02-nfs-rwx | spike02-nfs | ReadWriteMany | an in-cluster NFS server whose own export sits on a claim on standard; shared by many Pods |
| pvc | spike02-pvc | standard | ReadWriteOnce | a directory on the node, made by the local-path provisioner |
| hostpath | none — hostPath volume | none | none | the worker's bind mount, set when the node was created |
