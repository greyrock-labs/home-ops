# doco-cd on the docker hosts

doco-cd deploys `docker/<host>/` from `main`, but it does not pick a push up quickly.
After pushing a change for codswallop, restart it so it deploys straight away rather than
waiting:

```sh
command ssh truenas_admin@codswallop.internal.greyrock.io 'sudo -n docker restart doco-cd'
```

`docker` needs `sudo` there; the `truenas_admin` user is not in the docker group.
