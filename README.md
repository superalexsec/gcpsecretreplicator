# GCP Secret Manager Replicator

A Bash utility to replicate all secrets from one Google Cloud project to another using **Secret Manager**.  
It preserves **replication policy**, **labels**, and **secret contents** while ensuring that **no secret data is ever written to disk**.

---

## Features
- ✅ Copies **all secrets** from a source project to a destination project  
- ✅ Preserves **replication policy** (`automatic` or `user-managed`)  
- ✅ Preserves **labels** on secrets  
- ✅ Copies **latest enabled version** by default  
- ✅ Optionally copy **all enabled versions** (set a flag)  
- ✅ Logs status and errors to a file (`replicate-secrets_<SRC>_to_<DST>_<timestamp>.log`)  
- ✅ Colored console output for readability  
- ✅ Resilient: continues even if some secrets fail, logs the failures  

---

## Requirements
- [Google Cloud SDK (`gcloud`)](https://cloud.google.com/sdk/docs/install)  
- [jq](https://stedolan.github.io/jq/)  
- Both projects (`SOURCE_PROJECT` and `DEST_PROJECT`) must be accessible via your current gcloud authentication.

---

## Usage

```bash
chmod +x gcpsecretreplicator.sh
```

```bash
./gcpsecretreplicator.sh <SOURCE_PROJECT_ID> <DEST_PROJECT_ID>
```
