# Onboarding users

1. Establish a project name.

    Each person using our services needs to belong to a project. The project name should follow Kubernetes naming restrictions:

    - Length: Maximum of 63 characters.
    - Characters: Only lowercase letters (a-z), numbers (0-9), and hyphens (-).
    - Start/End: Must start with an alphabetic character and end with an alphanumeric character

  2. For each project, create a Keycloak group named `project-<project_name>-edit` by submitting a pull request against <https://github.com/CCI-MOC/moc-keycloak/blob/main/groups.tf> or by opening an issue in [moc-issues](https://github.com/CCI-MOC/MOC-issues) and assigning it to someone from the [keycloak-workers] team.

  3. For each project, create a pull request adding an entry to <https://github.com/CCI-MOC/oac-apps/blob/main/values/oac-prod-infra/oac-prod-workload0/user-projects.yaml>. A minimal entry may look like this:

      ```
      projects:
      - name: super-duper
        description: "Really cool stuff. Totally mind blowing."
      ```

      This will create a namespace on the `oac-prod-workload0` cluster named `project-super-duper` and create RBAC granting members of the keycloak `project-super-duper-edit` group access to the namespace. This will apply default quotas to the namespace (see <https://github.com/CCI-MOC/oac-apps/blob/main/charts/user-projects/values.yaml> for the default values). You can override these defaults when defining the project:

      ```
      projects:
      - name: super-duper
        description: "Really cool stuff. Totally mind blowing."
        quota:
          hard:
            pods: "100"
            limits.cpu: "50"
            limits.memory: "128Gi"
            limits.nvidia.com/gpu: "2"
      ```

4. Get a list of email addresses for project members, and submit these to someone on the [keycloak-workers] team. We will preconfigure these addresses in Keycloak and assign them to the appropriate group.

[keycloak-workers]: https://github.com/orgs/CCI-MOC/teams/keycloak-workers
