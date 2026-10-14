# SPDX-License-Identifier: MIT
"""D-Bus objects on a Gio connection, the way ModemManager's skeletons
behave on the wire:

- properties are read-only and served from a Python store; Get, GetAll and
  Introspect come from Gio, from the interface XML in mm_api;
- changes are batched per object and interface into one PropertiesChanged
  in an idle callback (as GDBusInterfaceSkeleton does). Before a signal of
  ours the pending changes go out first, so a client reading a property in
  its signal handler sees the new value;
- the modems are announced by org.freedesktop.DBus.ObjectManager on the
  manager's path; SIM, bearer, SMS and call objects are plain objects, as
  in MM;
- methods with a polkit action in mm_api.ACTIONS are authorised first:
  root always (as polkit does), everyone else through polkit's
  CheckAuthorization for the calling bus name, unless polkit is off.
"""
import os
import traceback

from gi.repository import Gio, GLib

import mm_api

VARIANT_DEFAULTS = {'s': '', 'o': '/', 'b': False, 'u': 0, 'i': 0, 'ay': b''}


def default(signature):
    if signature in VARIANT_DEFAULTS:
        return VARIANT_DEFAULTS[signature]
    if signature.startswith('a{'):
        return {}
    if signature.startswith('a'):
        return []
    return {'(uu)': (0, 0), '(ub)': (0, False), '(ss)': ('', ''),
            '(uv)': (0, GLib.Variant('u', 0)), '(ua{sv})': (0, {})}[signature]


class Reply:
    """The answer to one method call."""
    def __init__(self, invocation, interface, method):
        self.invocation = invocation
        self.signature = mm_api.out_signature(interface, method)
        self.done = False

    def ok(self, *values):
        if self.done:
            return
        self.done = True
        self.invocation.return_value(GLib.Variant(f'({self.signature})', values)
                                     if self.signature else None)

    def error(self, error):
        if self.done:
            return
        self.done = True
        self.invocation.return_dbus_error(error.name, error.message)


class Exporter:
    def __init__(self, connection, *, polkit=True):
        self.connection = connection
        self.polkit = polkit
        self.infos = {name: Gio.DBusNodeInfo.new_for_xml(
            f'<node>{mm_api.introspection(name)}</node>').interfaces[0] for name in mm_api.INTERFACES}
        self.objects = {}        # path -> {'interfaces': {name: props}, 'ids': {}, 'handler', 'managed'}
        self.pending = {}        # (path, interface) -> {property: value}
        self.flush_source = None

    # ---- objects ---------------------------------------------------------

    def add(self, path, interfaces, handler, *, managed=False):
        """Export an object with {interface: {property: value}}; missing
        properties get MM's empty values."""
        self.objects[path] = dict(interfaces={}, ids={}, handler=handler, managed=managed)
        for name, props in interfaces.items():
            self._register(path, name, props)
        if managed:
            self.emit(mm_api.PATH, mm_api.OBJECT_MANAGER, 'InterfacesAdded', '(oa{sa{sv}})',
                      (path, self._all(path)))

    def add_interface(self, path, name, props):
        if name in self.objects[path]['interfaces']:
            return
        self._register(path, name, props)
        if self.objects[path]['managed']:
            self.emit(mm_api.PATH, mm_api.OBJECT_MANAGER, 'InterfacesAdded', '(oa{sa{sv}})',
                      (path, {name: self._props(path, name)}))

    def remove_interface(self, path, name):
        obj = self.objects.get(path)
        if not obj or name not in obj['interfaces']:
            return
        self.flush()
        self.connection.unregister_object(obj['ids'].pop(name))
        del obj['interfaces'][name]
        self.pending.pop((path, name), None)
        if obj['managed']:
            self.emit(mm_api.PATH, mm_api.OBJECT_MANAGER, 'InterfacesRemoved', '(oas)', (path, [name]))

    def remove(self, path):
        obj = self.objects.get(path)
        if not obj:
            return
        self.flush()
        names = list(obj['interfaces'])
        for name in names:
            self.connection.unregister_object(obj['ids'][name])
            self.pending.pop((path, name), None)
        del self.objects[path]
        if obj['managed']:
            self.emit(mm_api.PATH, mm_api.OBJECT_MANAGER, 'InterfacesRemoved', '(oas)', (path, names))

    def has(self, path, name=None):
        return path in self.objects and (name is None or name in self.objects[path]['interfaces'])

    def _register(self, path, name, props):
        spec = mm_api.INTERFACES[name]['properties']
        unknown = set(props) - set(spec)
        if unknown:
            raise KeyError(f'{name} has no properties {sorted(unknown)}')
        values = {p: props.get(p, default(sig)) for p, sig in spec.items()}
        self.objects[path]['interfaces'][name] = values
        register = getattr(self.connection, 'register_object_with_closures2', None) or \
            self.connection.register_object
        self.objects[path]['ids'][name] = register(path, self.infos[name], self._call, self._get, None)

    # ---- properties --------------------------------------------------------

    def _variant(self, name, prop, value):
        return GLib.Variant(mm_api.INTERFACES[name]['properties'][prop], value)

    def _props(self, path, name):
        return {p: self._variant(name, p, v) for p, v in self.objects[path]['interfaces'][name].items()}

    def _all(self, path):
        # Only MM's own interfaces: libmm-glib makes info-less proxies for
        # anything else, and GNOME Calls 51.1 crashed on one
        # (calls-mm-provider.c:162 reads info->name).
        return {name: self._props(path, name) for name in self.objects[path]['interfaces']}

    def get(self, path, name, prop):
        return self.objects[path]['interfaces'][name][prop]

    def set(self, path, name, **props):
        """Update properties; changed ones go out in one PropertiesChanged."""
        store = self.objects[path]['interfaces'][name]
        for prop, value in props.items():
            if prop not in store:
                raise KeyError(f'{name}.{prop}')
            if _same(store[prop], value):
                continue
            store[prop] = value
            self.pending.setdefault((path, name), {})[prop] = value
        if self.pending and self.flush_source is None:
            self.flush_source = GLib.idle_add(self._flush_idle)

    def _flush_idle(self):
        self.flush_source = None
        self.flush()
        return False

    def flush(self):
        pending, self.pending = self.pending, {}
        for (path, name), props in pending.items():
            if not self.has(path, name):
                continue
            changed = {p: self._variant(name, p, v) for p, v in props.items()}
            self.connection.emit_signal(None, path, 'org.freedesktop.DBus.Properties', 'PropertiesChanged',
                                        GLib.Variant('(sa{sv}as)', (name, changed, [])))

    def emit(self, path, name, signal, signature, args):
        self.flush()
        self.connection.emit_signal(None, path, name, signal, GLib.Variant(signature, args))

    def managed_objects(self):
        return {path: self._all(path)
                for path, obj in self.objects.items() if obj['managed']}

    # ---- calls -------------------------------------------------------------

    def _get(self, connection, sender, path, name, prop):
        return self._variant(name, prop, self.get(path, name, prop))

    def _call(self, connection, sender, path, name, method, parameters, invocation):
        reply = Reply(invocation, name, method)
        obj = self.objects.get(path)
        if obj is None or name not in obj['interfaces']:
            return reply.error(mm_api.MMError('NotFound', 'No such object'))
        args = parameters.unpack()

        def authorised(allowed):
            if not allowed:
                return reply.error(mm_api.MMError('Unauthorized', 'PolicyKit authorization failed'))
            try:
                obj['handler'](name, method, args, reply)
            except mm_api.MMError as error:
                reply.error(error)
            except Exception as error:  # a bug of ours must not leave the caller hanging
                print(f'Error handling {name}.{method}: {type(error).__name__}', flush=True)
                if os.environ.get('OMAMOBILE_MMD_DEBUG'):
                    traceback.print_exc()
                reply.error(mm_api.MMError('Failed', 'Internal error in omamobile-mmd'))
        action = mm_api.ACTIONS.get((name, method))
        if action is None:
            authorised(True)
        else:
            self.authorise(sender, action, authorised)

    def authorise(self, sender, action, done):
        if not self.polkit:
            return done(True)

        def checked(connection, result):
            try:
                allowed = connection.call_finish(result).unpack()[0][0]
            except GLib.Error:
                allowed = False
            done(allowed)

        def uid(connection, result):
            try:
                caller = connection.call_finish(result).unpack()[0]
            except GLib.Error:
                return done(False)
            if caller == 0:
                return done(True)
            subject = ('system-bus-name', {'name': GLib.Variant('s', sender)})
            # Flag 1: AllowUserInteraction (an agent may ask the user).
            self.connection.call('org.freedesktop.PolicyKit1', '/org/freedesktop/PolicyKit1/Authority',
                                 'org.freedesktop.PolicyKit1.Authority', 'CheckAuthorization',
                                 GLib.Variant('((sa{sv})sa{ss}us)', (subject, action, {}, 1, '')),
                                 GLib.VariantType('((bba{ss}))'), Gio.DBusCallFlags.NONE, 120000,
                                 None, checked)
        self.connection.call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                             'GetConnectionUnixUser', GLib.Variant('(s)', (sender,)),
                             GLib.VariantType('(u)'), Gio.DBusCallFlags.NONE, 5000, None, uid)


def _same(a, b):
    try:
        return type(a) is type(b) and a == b
    except TypeError:
        return False
