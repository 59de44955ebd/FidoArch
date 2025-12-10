# FidoArch: A PowerShell script to download Windows ISOs from archive.org.

## Description

[FidoArch](https://raw.githubusercontent.com/59de44955ebd/FidoArch/refs/heads/main/FidoArch.ps1) is a modified clone of [Fido](https://github.com/pbatard/Fido) (also integrated into [Rufus](https://github.com/pbatard/rufus)) that allows to select and download Windows OS setup ISOs from [archive.org](https://archive.org/). 

Since it doesn't depend on MS servers, it also allows to download ISOs for various legacy systems (see first screenshot below). But as file metadata on archive.org is not sufficiently structured, stuff like architecture and language can't really be pre-filtered correctly, you have to pick an appropriate .iso yourself from the "Edition" list, based on its name.

It's basically just a fun project, but maybe still useful for someone.

## Screenshots

![](screenshots/fido-arch.png)  
![](screenshots/fido-arch-win-11.png)  
![](screenshots/fido-arch-win-nt.png)
