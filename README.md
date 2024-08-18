# LMKD PSI Activator
Magisk module to fix RAM management by activating psi mode in LMKD which is more efficient, faster and more stable than traditional minfree_levels most ROMs used
> [!CAUTION]
> For MIUI user this module is gonna make your phone more aggressive and killing app like VPN more often, please install [NoSwipeToKill](https://github.com/dantmnf/NoSwipeToKill) lsposed module by [dantmnf](https://github.com/dantmnf) to prevent this

## TODO

- [ ] Install amazing module [NoSwipeToKill](https://github.com/dantmnf/NoSwipeToKill) by [dantmnf](https://github.com/dantmnf) to really make this module working as expected in MIUI, ending the pain of RAM management bullshit in MIUI, no more VPN killed, the truth is I'm trying to do something similiar but completely missed the point.
- [x] Adressing ghost touch issue and navigation gesture not working on MIUI because you can't touch the edge of the screen, something wrong with the thermal probably. 
> [!NOTE]
> It's apparently because of the previous installation of MIUI on my Redmi 10C phone(Fog), that why I got a ghost touch issue, The MIUI mod from the Redmi 10C community I got probably has a bug and somehow even when I reflash my phone from official source it's still not fixed, only after I dirty flash `miui_FOGGlobal_V13.0.5.0.SGEMIXM_b24fadf4ba_12.0.zip` and update to `miui_FOGGlobal_V14.0.7.0.TGEMIXM_456a385a29_13.0.zip` the ghost touch issue is gone, I don't understand what happened maybe because the vendor partition, the custom ROMs from that community is also having the same problem, I can't believe how much trouble they gave because of this.
