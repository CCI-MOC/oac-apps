# Network Inventory and Configuration

## Network Inventory

VLANs are tracked in [`vlans.yaml`](https://github.com/CCI-MOC/ansible-switches/blob/main/group_vars/all/vlans.yaml) within the [`ansible-switches` repository](https://github.com/CCI-MOC/ansible-switches/). An entry looks like the following:

```
  - id: 216
    name: OPENACCELERATOR-PRODUCTION
    description: OAC Production Net  10.20.12.0 /23
    fabrics:
      - moc
      - nerc
```

## Firewall

*TBD*

## DNS

*TBD*
