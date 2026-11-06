# eznotify

A message when a service has finished or failed. Each way of sending is its own switch, and
any number can be on: `mail` (an SMTP account of your own) and `desktop` (a popup on one user's
desktop, via the freedesktop notification service that GNOME, KDE, XFCE and others share).

## ✨ Features

- Any number of services, each with its own choice of telling about failure, success or both
- The mail has the service's status and its last log lines
- The password is read from a file when a mail is sent, never put in the Nix store
- One template unit does the work, so a service only needs a line in `units`

## 🚀 Quick Start

```nix
services.eznotify = {
  enable = true;
  desktop.user = "alice";   # a popup on alice's desktop
  mail = {
    to = "you@example.com";
    from = "ezbox@example.com";
    smtp = {
      host = "smtp.example.com";
      user = "ezbox@example.com";
      passwordFile = "/etc/eznotify-password";
    };
  };
  units = {
    nixos-upgrade = {
      onFailure.logLines = 60;
      onSuccess = { enable = true; logLines = 5; };
    };
    restic-backups-home = { };   # failure only
  };
};
```

Put the account's password alone in `/etc/eznotify-password` (mode 600, owned by root). To
try it after a rebuild: `sudo systemctl start eznotify@nixos-upgrade.service`.

## 📋 Options

| Option | Type | Default | Description |
|---|---|---|---|
| `services.eznotify.enable` | bool | false | Enable eznotify |
| `services.eznotify.desktop.enable` | bool | `user != null` | Show a popup in one user's desktop. On once `user` is set |
| `services.eznotify.desktop.user` | str or null | null | The user whose desktop shows it. Nothing is shown while they are logged out |
| `services.eznotify.desktop.logLines` | int | 3 | Log lines of the service in the popup when it fails. A success popup has none |
| `services.eznotify.mail.enable` | bool | `to != null` | Send a mail. On once `to` is set; needs `from` and `smtp.host` too |
| `services.eznotify.mail.to` | str or null | null | Who the mail goes to |
| `services.eznotify.mail.from` | str or null | null | The sender address. Some providers only accept their own account's |
| `services.eznotify.mail.smtp.host` | str or null | null | The SMTP server |
| `services.eznotify.mail.smtp.port` | port | 587 | Its port: 587 for `starttls`, 465 for `tls` |
| `services.eznotify.mail.smtp.tls` | `"starttls"` or `"tls"` | `"starttls"` | Switch to TLS after connecting, or TLS from the start |
| `services.eznotify.mail.smtp.user` | str or null | null | Account to log in with. Null for a server that needs no login |
| `services.eznotify.mail.smtp.passwordFile` | str or null | null | File with the password, read as root. A string, not a path in the flake |
| `services.eznotify.units` | attrs | {} | Services to tell about, by name without `.service` |
| `services.eznotify.units.<name>.onFailure.enable` | bool | true | Send a message when the service fails |
| `services.eznotify.units.<name>.onFailure.logLines` | int | 30 | Log lines of the service in that mail |
| `services.eznotify.units.<name>.onFailure.lastRunOnly` | bool | true | Log lines from the run that just ended only. Off, they are the last lines of the service's journal, earlier runs included |
| `services.eznotify.units.<name>.onSuccess.enable` | bool | false | Send a message when the service ends well |
| `services.eznotify.units.<name>.onSuccess.logLines` | int | 30 | Log lines of the service in that mail |
| `services.eznotify.units.<name>.onSuccess.lastRunOnly` | bool | true | As `onFailure.lastRunOnly`, for the success mail |

## 📝 Notes

- `onSuccess` is for services that end: a oneshot, or the job of a timer such as `nixos-upgrade`. A service that keeps running never ends well, so it only has `onFailure`.
- The message is sent by the template `eznotify@.service`. `onFailure` and `onSuccess` are added to the listed services as a drop-in file, next to any such settings they have already. An entry for a service the machine does not have does nothing.
- Each way of sending turns on when its setting is given (`mail.to`, `desktop.user`); set its `enable = false` to switch it off and keep the settings. With neither on, eznotify warns that it sends nothing.
- The popup is shown by entering the user's session bus as that user. A failing popup never fails the service, so the mail still goes out.
- Most providers want an app password rather than the account's own (Gmail does), and mail from a home connection without an account is often refused.

*eznotify is part of eznixpkgs.*
