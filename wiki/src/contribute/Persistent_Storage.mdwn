# Adding new Persistent Storage features

Take these steps to add a new preset feature to the Persistent Storage:

1. Add a new `Feature` subclass to
   `config/chroot_local-includes/usr/lib/python3/dist-packages/tps/configuration/features.py`.
2. Add a new `Feature` subclass to
   `/home/user/projects/tails/config/chroot_local-includes/usr/lib/python3/dist-packages/tps_frontend/views/features_view.py`
3. Add a new `HdyActionRow` child to the `GtkListBox` of the
   corresponding section you want to add the feature to.
