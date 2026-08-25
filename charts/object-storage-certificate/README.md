# object-storage-certificate

Request a certificate for `storage.massopen.cloud`, the hostname used by the [object-storage-proxy](../object-storage-proxy), and use a [PushSecret] to sync the generated certificate to our AWS secret store. This allos the secret to be consumed by the in-cluster object storage proxy on multiple clusters.

[pushsecret]: https://external-secrets.io/latest/guides/pushsecrets/
