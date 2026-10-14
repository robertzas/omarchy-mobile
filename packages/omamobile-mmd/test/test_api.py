# SPDX-License-Identifier: MIT
"""The interface tables against ModemManager's own introspection XML (when
installed, or MM_INTROSPECTION_DIR), and the shipped bus policy and polkit
actions against the tables."""
import env  # noqa: F401
import os
import unittest
import xml.etree.ElementTree as ET

import mm_api

PKG = os.path.join(env.HERE, '..')
CANDIDATES = [os.environ.get('MM_INTROSPECTION_DIR', ''), '/usr/share/dbus-1/interfaces']
MM_XML = next((d for d in CANDIDATES if d and os.path.exists(
    os.path.join(d, 'org.freedesktop.ModemManager1.Modem.xml'))), None)


def parse(path):
    found = {}
    for iface in ET.parse(path).getroot().iter('interface'):
        spec = dict(methods={}, signals={}, properties={})
        for member in iface:
            if member.tag == 'method':
                args = [(a.get('name'), a.get('type'), a.get('direction', 'in')) for a in member.iter('arg')]
                spec['methods'][member.get('name')] = (
                    [(n, t) for n, t, d in args if d == 'in'], [(n, t) for n, t, d in args if d == 'out'])
            elif member.tag == 'signal':
                spec['signals'][member.get('name')] = [(a.get('name'), a.get('type')) for a in member.iter('arg')]
            elif member.tag == 'property':
                spec['properties'][member.get('name')] = (member.get('type'), member.get('access'))
        found[iface.get('name')] = spec
    return found


@unittest.skipUnless(MM_XML, 'ModemManager introspection XML not installed (set MM_INTROSPECTION_DIR)')
class AgainstModemManager(unittest.TestCase):
    def test_every_interface_matches(self):
        theirs = {}
        for name in os.listdir(MM_XML):
            if name.startswith('org.freedesktop.ModemManager1') and name.endswith('.xml'):
                theirs.update(parse(os.path.join(MM_XML, name)))
        for name, ours in mm_api.INTERFACES.items():
            if name == mm_api.OBJECT_MANAGER:
                continue
            with self.subTest(interface=name):
                self.assertIn(name, theirs)
                spec = theirs[name]
                self.assertEqual(ours['methods'], spec['methods'])
                self.assertEqual(ours['signals'], spec['signals'])
                self.assertEqual({p: (t, 'read') for p, t in ours['properties'].items()}, spec['properties'])


class Tables(unittest.TestCase):
    def test_xml_parses_and_round_trips(self):
        for name in mm_api.INTERFACES:
            xml = f'<node>{mm_api.introspection(name)}</node>'
            spec = parse_string(xml)[name]
            self.assertEqual(spec['methods'], mm_api.INTERFACES[name]['methods'])
            self.assertEqual({p: t for p, (t, _) in spec['properties'].items()},
                             mm_api.INTERFACES[name]['properties'])

    def test_actions_name_real_methods(self):
        for (interface, method), action in mm_api.ACTIONS.items():
            self.assertIn(method, mm_api.INTERFACES[interface]['methods'], (interface, method))
            self.assertTrue(action.startswith('org.freedesktop.ModemManager1.'))

    def test_polkit_file_declares_every_action(self):
        root = ET.parse(os.path.join(PKG, 'polkit', 'org.freedesktop.ModemManager1.policy')).getroot()
        declared = {a.get('id') for a in root.iter('action')}
        self.assertLessEqual(set(mm_api.ACTIONS.values()), declared)

    def test_bus_policy(self):
        root = ET.parse(os.path.join(PKG, 'dbus', 'org.freedesktop.ModemManager1.conf')).getroot()
        policies = {p.get('user') or p.get('context'): p for p in root.iter('policy')}
        self.assertEqual(set(policies), {'root', 'default'})
        owners = [a for p in root.iter('policy') for a in p if a.get('own')]
        self.assertEqual([(a.tag, a.get('own')) for a in owners], [('allow', mm_api.SERVICE)])
        self.assertEqual(owners[0], policies['root'].find("allow[@own]"))
        default = policies['default']
        first = default[0]
        self.assertEqual((first.tag, first.get('send_type')), ('deny', 'method_call'))
        allowed = {(a.get('send_interface'), a.get('send_member')) for a in default.findall('allow')}
        for interface, member in allowed:
            self.assertTrue(interface, 'every allow names an interface')
            if member:
                self.assertIn(member, mm_api.INTERFACES[interface]['methods'], (interface, member))
        # Reading stays open, as in MM; the Voice and Messaging calls clients need are allowed.
        for needed in [('org.freedesktop.DBus.Properties', None), ('org.freedesktop.DBus.ObjectManager', None),
                       (mm_api.VOICE, 'CreateCall'), (mm_api.CALL, 'Accept'), (mm_api.CALL, 'Hangup'),
                       (mm_api.MESSAGING, 'Create'), (mm_api.SMS, 'Send'), (mm_api.MODEM, 'Enable')]:
            self.assertIn(needed, allowed)
        # GetCellInfo is root-only in MM too.
        self.assertNotIn((mm_api.MODEM, "Command"), allowed)  # MM allows it; we have no use for it
        self.assertNotIn((mm_api.MODEM, 'GetCellInfo'), allowed)


def parse_string(xml):
    import tempfile
    with tempfile.NamedTemporaryFile('w', suffix='.xml') as f:
        f.write(xml)
        f.flush()
        return parse(f.name)


if __name__ == '__main__':
    unittest.main()
