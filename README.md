# mongodb_administration

MongoDB operations toolkit. HA realtime check lives in [`mongodb_realtime_check/`](mongodb_realtime_check/).

```bash
cd mongodb_realtime_check
cp config/clusters/devmongo.example.env config/clusters/devmongo.env
./check_mongo_ha.sh -c config/clusters/devmongo.env -u a.abdolmaleki -y
```

Dual-git: GitHub `origin` + Azure DevOps `azure` (see `.cursor/rules/azure-devops.mdc`).
