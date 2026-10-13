# omamobile-keyring

The public key that signs Omarchy Mobile's packages and the `[omamobile]` repository
database, in pacman's keyring format. Installing it runs
`pacman-key --populate omamobile`, which imports the key and marks it trusted
(`omamobile-trusted`), the same way `archlinux-keyring` works.

The private key never leaves the build machine (`keys/`, ignored by git).
Fingerprint: `6C84FE3D240709E70E27CC94B301F5EA62B249FE`.
