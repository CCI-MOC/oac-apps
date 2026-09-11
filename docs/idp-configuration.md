# IDP Configuration

*TBD: IDP explanatory text*

## Request an OIDC Client in Keycloak

Request an OIDC Client in Keycloak by submitting a PR to the [`moc-keycloak` repository](https://github.com/CCI-MOC/moc-keycloak) modifying [`main.tf`](https://github.com/CCI-MOC/moc-keycloak/blob/main/main.tf) to add an entry for your cluster:

```
  locals {
    realm_id = "moc"
    openshift_oidc_clusters = {
      ...
      <cluster> = {
        cluster_name           = "<cluster>"
        openshift_redirect_uri = "<cluster oauth route>/oauth2callback/mocsso"
        client_secret_name     = "cluster/<cluster>/keycloak-oidc"
        keycloak_client_uuid   = "<cluster>"
      }
      ...
    }
  }
```

An infra cluster's oauth Route is named `oauth-openshift` in the `openshift-authentication` namespace. A workload cluster's oauth Route exists in its infra cluster, and is named `oauth` in the `clusters-<cluster name>` namespace.

Once the PR is merged, the cluster OIDC client will automatically be created.

## Configure Cluster

The steps for configuring a cluster to use an OIDC client depends on whether it is an infra cluster or a workload cluster.

### Infra Cluster

Submit a PR to the [`oac-apps` repository](https://github.com/CCI-MOC/oac-apps) adding `values/<infra-cluster>/local-cluster/keycloak-oauth.yaml`:

```
  keycloak:
    clientID: <cluster>

  externalSecret:
    remoteKey: cluster/<cluster>/keycloak-oidc
```

Once the PR is merged, the ArgoCD instance running on the infra cluster will automatically update the cluster configuration.

### Workload Cluster

Submit a PR to the [`oac-apps` repository](https://github.com/CCI-MOC/oac-apps) editing `hosted-clusters/<infra-cluster>/<cluster>/values.yaml`, adding the following sections:

```
  oauth:
    identityProviders:
      - name: mocsso
        mappingMethod: claim
        type: OpenID
        openID:
          clientID: <cluster>
          clientSecret:
            name: <cluster>-keycloak-client-secret
          claims:
            preferredUsername:
              - preferred_username
              - username
            name:
              - name
              - full name
            email:
              - email
            groups:
              - groups
          issuer: https://sso.massopen.cloud/realms/moc

  externalSecrets:
    - name: <cluster>-keycloak-client-secret
      spec:
        data:
          - remoteRef:
              conversionStrategy: Default
              decodingStrategy: None
              key: cluster/<infra-cluster>/hostedcluster/<cluster>/keycloak-oidc
              metadataPolicy: None
              nullBytePolicy: Ignore
              property: client_secret
            secretKey: clientSecret
        refreshInterval: 1h
        secretStoreRef:
          kind: ClusterSecretStore
          name: aws-secrets-manager
        target:
          creationPolicy: Owner
          deletionPolicy: Retain
          name: <cluster>-keycloak-client-secret
```

Once the PR is merged, the ArgoCD instance running on the infra cluster will automatically update the cluster configuration.

## Examples: OAC Prod Infra and Prod Workload0 IDP Configurations

* **OAC Prod Infra**:
   * `moc-keycloak`
      * [`main.tf`](https://github.com/CCI-MOC/moc-keycloak/blob/main/main.tf) (search for `oac_prod_infra`)
   * `oac-apps`
      * [`values/oac-prod-infra/local-cluster/keycloak-oauth.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/local-cluster/keycloak-oauth.yaml)
* **OAC Prod Workload0**:
   * `moc-keycloak`
      * [`main.tf`](https://github.com/CCI-MOC/moc-keycloak/blob/main/main.tf) (search for `oac_prod_workload0`)
   * `oac-apps`
      * [`hosted-clusters/oac-prod-infra/oac-prod-workload0/values.yaml`](https://github.com/CCI-MOC/oac-apps/blob/main/hosted-clusters/oac-prod-infra/oac-prod-workload0/values.yaml) (search for `oauth` and `externalSecrets`)
