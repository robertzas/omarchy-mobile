# SPDX-License-Identifier: MIT
"""Read-only: the modem as libmm-glib (GNOME Calls', Chatty's and
NetworkManager's library) sees it on the system bus. For runbooks on the
phone, where mmcli (in the modemmanager package) isn't installed:
  tools/phone-ssh python3 - < packages/omamobile-mmd/test/libmm-status.py
Prints states and counts only: no numbers, no message text."""
import warnings

warnings.filterwarnings('ignore')
import gi  # noqa: E402

gi.require_version('ModemManager', '1.0')
from gi.repository import Gio, ModemManager as MM  # noqa: E402

manager = MM.Manager.new_sync(Gio.bus_get_sync(Gio.BusType.SYSTEM, None),
                              Gio.DBusObjectManagerClientFlags.DO_NOT_AUTO_START, None)
print('ModemManager API', manager.get_version())
objects = manager.get_objects()
print('modems:', len(objects))
for obj in objects:
    modem = obj.get_modem()
    print(obj.get_object_path(), modem.get_manufacturer(), '/', modem.get_model())
    print('  state:', MM.modem_state_get_string(modem.get_state()),
          '| failed reason:', MM.modem_state_failed_reason_get_string(modem.get_state_failed_reason()),
          '| power:', MM.modem_power_state_get_string(modem.get_power_state()),
          '| unlock:', MM.modem_lock_get_string(modem.get_unlock_required()))
    print('  SIM object:', modem.dup_sim_path(), '| equipment id empty:', not modem.get_equipment_identifier())
    gpp = obj.get_modem_3gpp()
    if gpp:
        print('  3GPP registration:', MM.modem_3gpp_registration_state_get_string(gpp.get_registration_state()),
              '| IMEI empty:', not gpp.get_imei())
    voice = obj.get_modem_voice()
    if voice:
        print('  voice: emergency only', voice.get_emergency_only(), '| calls', len(voice.list_calls_sync(None)))
    messaging = obj.get_modem_messaging()
    print('  messaging:', 'sms ' + str(len(messaging.list_sync(None))) if messaging else 'not exported')
    print('  interfaces:', ', '.join(sorted(i.get_info().name.rsplit('.', 1)[-1] for i in obj.get_interfaces())))
