# Changelog

## 1.0.0 (2026-09-26)


### ⚠ BREAKING CHANGES

* **bitcoin:** the state that lived in the old container is not migrated (it is lost on the upgrade recreate either way). After upgrading, register the tower once more with `lightning-cli registertower <tower_id>`; from then on it survives upgrades and recreates.
* **bitcoin:** the first start migrates the wallet DB one-way - back up first (docs/disaster-recovery.md) and do not roll back. The backup plugin and the BACKUP_PLUGIN_COMPACT setting are removed. clboss v0.17 refuses to start on CLN older than v25.09.

### Features

* add darknet-retry-timeout and darknet-disallow-clearnet plugin options ([45a75b5](https://github.com/deymosh/bastion/commit/45a75b543afed1ba06f5151ac10b1c94bdba9b16))
* add hub landing page with links to all web panels ([dac267c](https://github.com/deymosh/bastion/commit/dac267c968fcf19ff9141c0b5eb5b295c08edee2))
* **ai:** bump CodeDeck+ bridge to v0.12.0, wire its new optional backends ([bb697d0](https://github.com/deymosh/bastion/commit/bb697d0ef78c28bea7f320703cd96cefbe3dd400))
* **ai:** CCR OAuth token refresher and gateway model discovery ([b933623](https://github.com/deymosh/bastion/commit/b933623d402ae859c34ac3e38bd14267788d38e1))
* **ai:** one bearer-authenticated MCP gateway on :8811 ([4cc5caa](https://github.com/deymosh/bastion/commit/4cc5caafd9320a0bc9c11196eada15bcf441ce5a))
* **ai:** opt-in private Docker daemon for the agent, on Sysbox ([1724880](https://github.com/deymosh/bastion/commit/1724880f7996b5b667552d164f031b5b8f0c85fb))
* **ai:** opt-in private Docker daemon for the agent, on Sysbox ([b2f7082](https://github.com/deymosh/bastion/commit/b2f70829e80533a9c9ca327ab7ae957ab476f08b))
* **ai:** send MCP server instructions from the gateway ([942f844](https://github.com/deymosh/bastion/commit/942f844756aedfbf776537999b8b219410efaea7))
* **ai:** single bearer-authenticated MCP gateway for remote agents ([7632308](https://github.com/deymosh/bastion/commit/7632308898624a37c5322c8eb500841913192d3e))
* **bitcoin:** amboss heartbeat via docker exec, no host Tor port ([5ff725e](https://github.com/deymosh/bastion/commit/5ff725e3ae2809db1925eeaea46ee10660ceeb81))
* **bitcoin:** default RTL to night mode with a yellow accent ([0ef13c5](https://github.com/deymosh/bastion/commit/0ef13c5da87b71989f7db7cf6b09cdd816b4daa3))
* **bitcoin:** seed teos.toml on the opt-in watchtower path ([8244c7b](https://github.com/deymosh/bastion/commit/8244c7b64914efe823d96f74691090e6d1d89c6e))
* **bitcoin:** upgrade Core Lightning to v26.06.8, rework the plugin set ([a9a2fd6](https://github.com/deymosh/bastion/commit/a9a2fd69c2646db6f7605e4f3e006fe694e226c1))
* **cli:** idempotent RTL/config seeding, make teosd opt-in ([2bd1730](https://github.com/deymosh/bastion/commit/2bd17306304abf19ee941cd32a1fb6be1ae0b3aa))
* **cli:** interactive TUI and per-stack subcommands for bastion ([e05aa30](https://github.com/deymosh/bastion/commit/e05aa30c63118f6255709ba5f8d80b332ec8e0e7))
* **cli:** make stack-network mandatory for every other stack ([dd0ef0a](https://github.com/deymosh/bastion/commit/dd0ef0afc4428c9d4e5627c967f04e46c75c38f5))
* **cli:** per-container restart/stop/start/logs/exec/shell + TUI Containers view ([4ca9760](https://github.com/deymosh/bastion/commit/4ca9760547aaee693af6246cedb46902b6ebf01f))
* **compose:** healthchecks for every probeable service ([58b61d0](https://github.com/deymosh/bastion/commit/58b61d0cdba92be52ee6e83952082cb6a2038bbb))
* **config:** deliver secrets as mounted files, not env vars ([51ab4a7](https://github.com/deymosh/bastion/commit/51ab4a7a481158e4383a83bf2fdfeec01c76e5eb))
* **config:** expose the CCR token-refresher knobs in bastion.conf/TUI ([96a4e09](https://github.com/deymosh/bastion/commit/96a4e09ecdebce7d4a4c4197040fc6a3a7466182))
* **config:** persisted opt-in profiles, daemon settings, `./bastion config` ([91d621e](https://github.com/deymosh/bastion/commit/91d621e152ac45afc5988485901cfcfb52166021))
* **monitor:** let the Hub embed Grafana; document why Portainer can't ([ab02258](https://github.com/deymosh/bastion/commit/ab022583a14fa9b6432aad0267af683b3c91f27e))
* **tui:** faster Containers view, opt-in services in the deploy picker ([0ff237e](https://github.com/deymosh/bastion/commit/0ff237e1f7177fc957f733c1af76aa9f005379eb))
* **tui:** focusable status pane, scrollable dialogs, esc stops quitting ([11ce284](https://github.com/deymosh/bastion/commit/11ce2849a6ceeff3dfd9c72d3910635cc7bae830))
* **tui:** give the menu pane the larger share of the width ([023b215](https://github.com/deymosh/bastion/commit/023b21522256389f0545fc7dfa307f8da78bcfbf))
* **tui:** group the Configuration view by registry section ([686e561](https://github.com/deymosh/bastion/commit/686e561a362451bc463e1ac3c6e55ac68dc2abc1))
* **tui:** group the Configuration view by section ([3b3f347](https://github.com/deymosh/bastion/commit/3b3f34746fa78ebfaa2eb7123f7178308e399238))
* versioned releases via release-please, `./bastion version` ([f730144](https://github.com/deymosh/bastion/commit/f7301441c7f1bf06bcc9bb8630af67fa8ec758a2))
* **web:** keep service navigation inside the Hub instead of new tabs ([6bbaffa](https://github.com/deymosh/bastion/commit/6bbaffaac033abaa47b7c5c93617d0d4d9e23282))
* **web:** use the Bastion mark in the hub header, give CCR its own icon ([74d6e45](https://github.com/deymosh/bastion/commit/74d6e45de686e1201b887a874477d42d771c23c0))


### Bug Fixes

* add gitignore to stack-web ([bb955c1](https://github.com/deymosh/bastion/commit/bb955c1438ee3d2316658a0597702162ad7f03e5))
* **ai:** honour refreshTokenExpiresAt in the CCR token refresher ([82caac0](https://github.com/deymosh/bastion/commit/82caac0d75d1341c8dbe3a5d462322e6e5fa3a2a))
* **ai:** install-sysbox no longer fails after a successful install ([d7ba019](https://github.com/deymosh/bastion/commit/d7ba0195813c4309dd4b81c62fc39c246a8cea55))
* **ai:** resolve the CCR refresher relative to the wrapper ([d4e9ba4](https://github.com/deymosh/bastion/commit/d4e9ba4cdc7d488be93e2a606dbc91ede5ad18f6))
* **ai:** the CCR token refresher must never gate CCR startup ([304a887](https://github.com/deymosh/bastion/commit/304a887e834d49c1914ac3f375c97fff56ed2501))
* apply findings from the branch self-review ([2c392f9](https://github.com/deymosh/bastion/commit/2c392f9a018f9ad76ffddf6e57da749055b0ebaf))
* **bitcoin:** actually load peerswap.conf - Bitcoin swaps only ([4da01b4](https://github.com/deymosh/bastion/commit/4da01b4f45c1740619c82b1e9dac7a26d596c098))
* **bitcoin:** fail the CLN image build when pyln-client cannot install ([c6d53bb](https://github.com/deymosh/bastion/commit/c6d53bb88a5d4a29bd1271e2e9c0226eb1ecba60))
* **bitcoin:** peerswap v7.0.1, label the clboss pin as v0.17.1-rc1 ([cc8a3ca](https://github.com/deymosh/bastion/commit/cc8a3ca52640d0be62c41b4f241d601845857362))
* **bitcoin:** persist watchtower-client state across container recreates ([380422c](https://github.com/deymosh/bastion/commit/380422cc82195a7f28a2e79327e18abfd1b8ea1d))
* **bitcoin:** replicate the CLN wallet to BACKUP_DEST, warn when unmounted ([ca049de](https://github.com/deymosh/bastion/commit/ca049deb0bec06a57a6b462c7cd9b6234d1bfa83))
* **bitcoin:** stop Core Lightning cleanly instead of SIGKILL ([11c446b](https://github.com/deymosh/bastion/commit/11c446b3fc77163159ebccff10ead4edfd15f36b))
* **cli:** ask for config only when a command actually needs it ([0d32c74](https://github.com/deymosh/bastion/commit/0d32c74ce1dc9dfdf870bed321aca8a40ff103ba))
* **cli:** convert --env-file for exec/shell when MSYS_NO_PATHCONV is set ([8733fc9](https://github.com/deymosh/bastion/commit/8733fc98d7322467ea2c874c5a24bf3e6c5f60f2))
* **config:** generated CCR and MCP tokens are always 43 characters ([16e0212](https://github.com/deymosh/bastion/commit/16e0212f9bd936ad74d6264a9cf281d3140207f1))
* **daemon:** unit path, atomic and mount-checked channel backups ([ac6710a](https://github.com/deymosh/bastion/commit/ac6710ab0b2ff0a7e22fa39b086abe67d97ac4bf))
* **mcp-gateway:** install libatomic1 for the copied node binary ([d534f9e](https://github.com/deymosh/bastion/commit/d534f9e9b3ad752cc95b81e567ecc17df1d63edf))
* **mcp-gateway:** install libatomic1 for the copied node binary ([dfbe0c4](https://github.com/deymosh/bastion/commit/dfbe0c4d84432aea11a1c2928015131177084db4))
* **monitor:** node-exporter reports the host filesystems ([eda3b94](https://github.com/deymosh/bastion/commit/eda3b946dc8a818f272397c2433a58e3c18e41a2))
* **network:** harden startup ordering and Tor-consumer addressing ([b457106](https://github.com/deymosh/bastion/commit/b4571063856c2768648b845a733cf3d6811dfb85))
* **network:** land the transit-network migration, simplify the Tor image ([b26e559](https://github.com/deymosh/bastion/commit/b26e559ce374c9e1253ebcac9cb1cca0187f2bbd))
* **network:** route CLN and TEOS onion targets through bastion-transit ([c864971](https://github.com/deymosh/bastion/commit/c86497130baeb631ace2fa88df05a42e84415034))
* **release:** only feat/fix/perf/revert open a release PR ([52debb7](https://github.com/deymosh/bastion/commit/52debb7cbd42144080dd0e5c6368ccce2b21a299))
* set entrypoint of custom lightningd build as original image ([3c4d848](https://github.com/deymosh/bastion/commit/3c4d84853ed64e1fbc6553014fd4a2db584f5823))
* **tests:** make the MCP test token readable on Linux CI ([872e53d](https://github.com/deymosh/bastion/commit/872e53d085cc4cb5bc9ceacc795afbcfb35db58a))
* **tests:** TUI container count and MCP test-secret permissions ([57178d3](https://github.com/deymosh/bastion/commit/57178d3f75690cccf66573e330a0d43f4885ba2b))
* track mapped folders to prevent docker creating them as root ([4b425ee](https://github.com/deymosh/bastion/commit/4b425eecd3f87972d9f122593b7ab6748854c9cb))
* translate hub landing page to English ([11bc12c](https://github.com/deymosh/bastion/commit/11bc12c6d3fc8448c8377f084bef9b2cacb06d82))
* **tui:** drop now-unused TUI_STATUS_TOTAL ([b19fded](https://github.com/deymosh/bastion/commit/b19fded387f4fd1e6477841face96a107195a4b6))
* **tui:** status pane scroll can now reach the last row ([4878f71](https://github.com/deymosh/bastion/commit/4878f7148660ef7f8cb92f6e6699425bd101f8fc))
* **tui:** stop stripping hyphens from free-text config input ([2f421f6](https://github.com/deymosh/bastion/commit/2f421f6850a285a97e3aa465e55cfd7fb797a68a))
* **web:** keep the BASTION wordmark visible on mobile home ([fc0ba93](https://github.com/deymosh/bastion/commit/fc0ba93d20bdec736bb215f7bf93166f677e979f))
* **web:** return Home in one Back press from an embedded service ([3ce728d](https://github.com/deymosh/bastion/commit/3ce728de1bf1282af0f02a4648e7813f291dd068))
* **web:** stop fake-embedding services that refuse framing, fix review findings ([5de48c8](https://github.com/deymosh/bastion/commit/5de48c82f28371159f2cd5a451699dc23dbd8d10))


### Performance

* **config:** load bastion.conf without a subshell per value ([dcfe730](https://github.com/deymosh/bastion/commit/dcfe730da8dabd58e476cdec6efabc5ed3bbcaa4))
* **tui:** non-blocking status probe, scrolling menus, compact panels ([d4b376a](https://github.com/deymosh/bastion/commit/d4b376ac267fb63b64f931ce2b678f33445d601c))

## Changelog

All notable changes to Bastion. Maintained by release-please from the
Conventional Commit history; see [docs/releasing.md](docs/releasing.md).
