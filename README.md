# Layer Notify Slack Threaded

A Kaptain layer that adds the [Slack threaded notify plugin](https://github.com/kube-kaptain/notify-slack-threaded)
to an environment's deploy image.

In a `prePackagePrepare` hook it:

1. Pulls `ghcr.io/kube-kaptain/notify/notify-slack-threaded:<version>` and extracts its `/scripts` and
   `/fields` into `notify-slack-threaded/extract/` within the configured or default output dir.
2. Copies `/scripts` into `run-package/bin/` within the configured or default output dir, which the build
   copies into the deploy image's `/kd/bin/`, beside the deploy scripts, with the plugin's library at `/kd/bin/lib/notify-slack.bash`.
3. Writes the entries `/fields` lists into `run-image-deploy-manifests/configmap/` and `run-image-deploy-manifests/secret.template/`
   within the configured or default output dir, as token references in your project's token styles. The
   build merges them into the environment's generated ConfigMap and Secret, which the deploy pod mounts
   at `/configmap/` and `/secret/`.
4. Writes each optional entry's token default, the plugin's own default from `/fields/defaults/`, into
   `run-image-deploy-manifests/defaults/` within the configured or default output dir. Your environment's own
   defaults and config win over them.

You then supply the required tokens in your run-platform's config, prefixed with the environment's project name
as the environment passphrase token is. For `run-stage` with the default token styles:

| Token                                         | Entry                    |
|-----------------------------------------------|--------------------------|
| `RunStage/NotifySlackThreaded/ChannelId`      | `slackChannelId`         |
| `RunStage/NotifySlackThreaded/AlertChannelId` | `slackAlertChannelId`    |
| `RunStage/NotifySlackThreaded/BotToken`       | `slackBotToken` (Secret) |

`slackContext` is always `deploy` in an env or rp.

Every optional entry is there too, as a token defaulting to the plugin's default, for example
`RunStage/NotifySlackThreaded/WarningPrefix` defaulting to `:warning:`. Override any of them in your config like any
other token, setting one empty turns that feature off. Every entry and default is listed in the plugin's
`notify-slack-threaded-fields.zip` release file, and in its image's `/fields`.


## Configuration

The plugin image defaults to a pinned and digest locked image with the scripts and token details and default values inside.

To use a mirror, a fork or another version, set the full image reference under `user-data.notify-slack-threaded`:

```yaml
user-data:
  notify-slack-threaded:
    image: registry.example.com/notify/notify-slack-threaded:1.2.3@sha256:e4ac0794dadae7413425bd70a155a44530dbe4f6124514713f01bf8899b7b8df
```

The layer uses the `prePackagePrepare` hook, so your project cannot use that hook while it uses this layer unless your hook script calls the layer script, `notify-slack-threaded-contribute.bash` in the configured or default output dir. It takes no arguments and needs only the environment your hook already has.
