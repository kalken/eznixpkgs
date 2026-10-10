# ezcert

Certificates for the services of a machine, signed by an authority of your own. Import the
authority once where a page should be trusted, and every service given a certificate here
stops producing warnings.

## ✨ Features

- Makes its own authority, or signs with one that exists already, such as the one eznix makes
- Any number of certificates, each for the names and addresses its service is reached by
- Each certificate is three plain files a service can be pointed at, readable by the group you name, and a Java keystore where a service wants that
- A new certificate when the names change, when the old one is about to run out, or when the authority is another one
- Restarts the services that use a certificate when it was made anew

## 🚀 Quick Start

```nix
services.ezcert = {
  enable = true;
  certs.web = {
    names = [ "myhost.lan" "192.168.1.10" ];
    group = "nginx";
    restart = [ "nginx.service" ];
  };
};

services.nginx.virtualHosts."myhost.lan" = {
  onlySSL = true;
  sslCertificate    = config.services.ezcert.certs.web.fullchain;
  sslCertificateKey = config.services.ezcert.certs.web.key;
};
```

After a rebuild the authority is `/var/lib/ezcert/ca.pem`. Import that file once in each
browser or system that should trust the machine's pages.

## 🔑 Using an existing authority

To have the certificates signed by an authority that is trusted already, name its two
files. With eznix on the same machine, one import then covers eznix and everything else:

```nix
services.ezcert = {
  enable = true;
  ca.cert = "/var/lib/eznix/ca.pem";
  ca.key  = "/var/lib/eznix/ca-key.pem";
  after   = [ "eznix.service" ];   # eznix makes them when it first starts
  certs.unifi.names = [ "ezbox.lan" ];
};
```

The files only have to exist when ezcert runs, not when the system is built. ezcert never
changes them.

## ☕ A Java keystore

Some services read their certificate only from a Java keystore. Name the file and ezcert
keeps the certificate there as well. The UniFi controller, with the alias and password it
has built in:

```nix
services.ezcert.certs.unifi = {
  names = [ "ezbox.lan" ];
  restart = [ "unifi.service" ];
  keystore = {
    path = "/var/lib/unifi/data/keystore";
    alias = "unifi";
    password = "aircontrolenterprise";
    user = "unifi";
    group = "unifi";
  };
};
services.ezcert.keytoolPackage = config.services.unifi.jrePackage;
```

The keystore is written again whenever it is missing, was made from another certificate, or
has been replaced by the service itself, so the configuration decides what is in it. The
folder has to exist already: on a machine where the service has never run, the keystore
appears at the run after its first start.

## 📁 The files

Each certificate is a folder of its name under `dir`:

| File | |
|---|---|
| `cert.pem` | the certificate |
| `fullchain.pem` | the certificate followed by the authority's, which is what most servers want |
| `key.pem` | its key, readable by `user` and `group` only |

Their paths are also options, so nothing has to be spelled out twice:
`config.services.ezcert.certs.NAME.cert`, `.fullchain` and `.key`.

## 🔄 Renewal

A certificate lasts `days` (365) and is made anew when fewer than `renewDays` (30) are left.
ezcert looks at every boot and once a week. The authority it makes itself lasts a hundred
years and is never replaced: everything that trusts it would have to be told again.

## 📋 Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `services.ezcert.enable` | bool | `false` | Enable ezcert |
| `services.ezcert.dir` | str | `"/var/lib/ezcert"` | Where the certificates are kept, and the authority ezcert makes |
| `services.ezcert.ca.cert` | null or str | `null` | Certificate of an existing authority to sign with; `null`: ezcert makes its own |
| `services.ezcert.ca.key` | null or str | `null` | Key of that authority; set together with `ca.cert` |
| `services.ezcert.ca.name` | str | `"ezcert (<hostname>)"` | What the authority ezcert makes is called |
| `services.ezcert.ca.path` | str | *read-only* | The certificate of the authority in use: the file to import |
| `services.ezcert.after` | list of str | `[]` | Units that must have run first, e.g. the one that makes an existing authority |
| `services.ezcert.certs.<name>.names` | list of str | required | Host names and addresses the certificate is for |
| `services.ezcert.certs.<name>.user` | str | `"root"` | Owner of the files |
| `services.ezcert.certs.<name>.group` | str | `"root"` | Group of the files; the key is readable by owner and group |
| `services.ezcert.certs.<name>.days` | int | `365` | How long a certificate lasts (Apple's systems refuse more than 825) |
| `services.ezcert.certs.<name>.renewDays` | int | `30` | Made anew when fewer days than this are left |
| `services.ezcert.certs.<name>.restart` | list of str | `[]` | Units restarted when the certificate was made anew |
| `services.ezcert.certs.<name>.keystore` | null or submodule | `null` | Also keep it as a Java keystore: `path`, `alias` (the certificate's name), `password` (`"changeit"`), `user`, `group` |
| `services.ezcert.certs.<name>.cert` / `.fullchain` / `.key` | str | *read-only* | Paths of the files |
| `services.ezcert.keytoolPackage` | package | `pkgs.jre_headless` | Where `keytool` comes from, for keystores |

## 📝 Notes

- ezcert writes files, and the service is pointed at them; for one that only reads a Java
  keystore it writes that too (see above). A service with yet another format of its own is
  best reached through a reverse proxy that uses the files.
- It does not make anything trust the authority either. That stays one import per browser
  or system.
- The work is done by `ezcert.sh` beside the module, which can be run by hand:
  `sh ezcert.sh ca DIR NAME` and `sh ezcert.sh cert OUT CA_CERT CA_KEY DAYS RENEW_DAYS OWNER GROUP NAME...`.
