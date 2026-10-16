# Connect another device to Herdr

AgentSpace connects over SSH to a Mac running Herdr. Ordinary password and SSH-key logins use the app's bundled bridge automatically: it uploads a verified versioned package into the account's private `~/.cache/agentspace/bridges/<SHA-256>/` directory and reuses persistent workers. It does not change SSH configuration. The computer needs Python 3 and a running Herdr server. Use the same address, port, username and password/key as your SSH app, then verify the host fingerprint in AgentSpace before saving.

Herdr is discovered in `~/.local/bin`, `~/.cargo/bin`, the SSH session's PATH, `/opt/homebrew/bin` or `/usr/local/bin`. The default socket is `~/.config/herdr/herdr.sock`. Missing Herdr or a missing running server produces a specific connection message. The bridge exposes the existing Herdr catalog, previews, explicit input and selected-terminal resizing. It does not start Herdr or submit input automatically.

You can also use a dedicated restricted key with the supplied server gate. Existing paired keys retain their restrictions. AgentSpace switches to the ordinary SSH bridge only when read-only catalog discovery receives a command-not-found response; a restricted gate's rejection does not trigger fallback. Input is never retried through another connection mode.

The connected computer also acts as a gateway to the enabled computers already saved in its Herdr. Their SSH keys/configuration stay on the gateway. Computer filters and per-computer setup states are available in the sidebar. See [persistent bridge](bridge-protocol.md).

## Optional restricted key setup

The gate permits catalog discovery and terminal observation; typing, logical keys, composed text + Enter and selected-terminal viewport control are opt-in. It rejects shell commands, PTYs and forwarding through the restricted authorized key.

These setup commands are for the owner to run on the Herdr Mac. The application never enables Remote Login or changes authorized_keys automatically.

1. Enable SSH Remote Login for the intended Mac account in macOS Settings. Use its reachable LAN hostname/address or an existing private VPN address.
2. Generate a dedicated RSA client key in a location you control:

   ```sh
   ssh-keygen -t rsa -b 4096 -f /path/to/agentspace-client
   ```

3. Keep catalog-gate.py and pair-client.py at a stable path on the Herdr Mac. Pair the public key:

   ```sh
   python3 /path/to/AgentSpace/scripts/pair-client.py --public-key /path/to/agentspace-client.pub
   ```

   Add `--allow-input` if this device should type, send logical keys, or submit text + Enter. Without it the connection is read-only. The script preserves unrelated authorized keys and replaces only the exact supplied public key. `--herdr` and `--socket` override the standard paths.

4. Display the Mac’s SSH host fingerprint using its public host key:

   ```sh
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
   ```

   SSH may negotiate a different installed host-key type. Compare the fingerprint shown by AgentSpace with the corresponding public host key on the Mac; trust it only after they match.

5. In AgentSpace **Settings → Add SSH connection**, enter the Mac host, port (normally 22), account username and dedicated private key/passphrase. On mobile, paste the private key into the credential field. Credentials are stored in platform secure storage; they are not written to the layout JSON. Select **Check host identity**, compare the result, then trust, save and connect.

The optional desktop private-key file path also needs file access permitted by the operating system. Pasting the key avoids that file-access requirement. Ordinary password login uses the cached bridge; it does not require this optional pairing setup.

To revoke a device, run the pairing script with its same public key and `--remove`. Do not move the gate afterward without updating the authorized key entry. No client key or account credentials are shipped with AgentSpace.

Direct terminal keyboard input requires the updated `catalog-gate.py` at the path used by the paired key. The gate advertises keyboard support separately; older gates retain composed-message input and observation. Copy the updated gate to its existing paired path before using keyboard input on another device. Multi-line paste opens in AgentSpace’s message box for review.

Zoom reflow requires the current catalog-gate.py on the paired server. It advertises terminalViewportEnabled only for keys paired with --allow-input. The new agentspace-control-v1 endpoint validates the live server/terminal, opens control without --takeover, and accepts only bounded terminal.resize records. Existing gates remain compatible through the observation view. AgentSpace releases its controller when leaving that selected terminal, backgrounding, changing source or closing.
