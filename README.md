# Cluster Template

This is a high availability cluster configuration.

1. Configure the OpenSSL-templates:

[] openssl/opensslCnfCaOrig.cnf
[] openssl/openSslCnfInterOrig.cnf

2. Configure the cluster node configurations (add more if needed):

[] nodes/*.nix

Then you can init your cluster, provision cloud nodes and deploy your cluster. When the cluster is deployed you need to configure your applications.

3. Add your application modules

[] app_modules/*
[] update app_modules/default.nix

Eventually you will want to direct your domains to the ingress node.

4. Configure ingress

[] domain CNAME to ingress node
[] nodes/ingress001.nix
