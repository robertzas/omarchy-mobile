# SPDX-License-Identifier: MIT
"""The start-up sequence for a freshly booted CP, using the service's IPC0
owner. This order registered on LTE with IMS voice and SMS on this phone:

  1. wait for the USIM application to be READY (type 2, state 5);
  2. radio off (AT+CFUN=0), initial attach APN, the default data profile;
  3. radio on (AT+CFUN=1), wait for packet registration;
  4. NR mode 0 ([network] nr = off): stay on LTE (NR registered, but
     carried no traffic on this phone), wait for LTE registration;
  5. the internet bearer (CID 1, rmnet0);
  6. IMS: stack start, the IMS bearer (CID 2, IPv6), ADD_PDN_INFO, then wait
     for an IMS registration with voice and SMS.

No retransmission of SMS/calls and no warm CP restart. A failed or uncertain
step ends start-up; the service exits and the modem stays up for diagnosis.
"""
import time

from at import radio
from data_call import activate, initial_attach, provision_default_profile
from ims import register, start_stack
from radio_settings import nr_mode


def sim_ready(payload):
    if len(payload) < 3 or payload[2] > 8 or len(payload) < 3 + payload[2] * 63:
        raise ValueError('Unexpected SIM status layout')
    return any(
        payload[i:i + 2] == bytes([2, 5])
        for i in range(3, 3 + payload[2] * 63, 63))


def packet_registered(payload, *, lte=False):
    return len(payload) >= 4 and payload[0] in (1, 5) and (not lte or payload[3] == 14)


def wait_for(service, predicate, seconds, stopped):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if stopped():
            raise InterruptedError('Modem startup stopped')
        service.pump()
        try:
            ready = predicate()
        except TimeoutError:
            # CP may briefly stop answering status requests while its SIM
            # application initializes. Only these read-only polls retry.
            ready = False
        if ready:
            service.pump()
            return
        # Receive and durably handle SMS throughout startup. Calls never
        # auto-answer; the same Service retains them for the user.
        until = time.monotonic() + 1
        while time.monotonic() < until:
            if stopped():
                raise InterruptedError('Modem startup stopped')
            packet = service.client.next_indication(.1)
            if packet:
                service.event(packet)
    raise TimeoutError('Modem registration deadline exceeded')


def start(service, settings, stopped=lambda: False):
    client = service.client
    net = settings['network']
    apn, ip_type = net.get('apn', ''), net.get('ip_type', 'ipv4v6')
    if not apn:
        raise RuntimeError('No APN configured: set [network] apn in /etc/omamobile/modem-sit.conf')
    previous = None

    def usim_ready():
        nonlocal previous
        payload = client.request(0x0200)
        ready = sim_ready(payload)
        # Card state and application type/state only: never AIDs or labels.
        state = (payload[0], tuple((payload[i], payload[i + 1])
                 for i in range(3, 3 + payload[2] * 63, 63)))
        if state != previous:
            print('SIM card state and application type/state:', state, flush=True)
            previous = state
        return ready
    service.stage('sim')
    print('Startup: waiting for physical USIM ready', flush=True)
    wait_for(service, usim_ready, net.getint('sim_timeout', 120), stopped)
    service.stage('attach')
    radio(False)
    initial_attach(client, apn, ip_type)
    provision_default_profile(client, apn, ip_type)
    service.pump()
    radio(True)
    service.stage('registering')
    print('Startup: waiting for packet registration', flush=True)
    timeout = net.getint('register_timeout', 180)
    wait_for(service, lambda: packet_registered(client.request(0x0701)), timeout, stopped)
    if net.get('nr', 'off') == 'off':
        nr_mode(client)
        wait_for(service, lambda: packet_registered(client.request(0x0701), lte=True), 120, stopped)
    service.stage('data')
    activate(client, apn, ip_type=ip_type)
    service.pump()
    if not net.getboolean('ims', True):
        print('Startup: registered with data; IMS off ([network] ims = no)', flush=True)
        return
    service.stage('ims')
    start_stack(client)
    activate(client, net.get('ims_apn', 'ims'), ims=True)
    register(client)
    print('Startup: waiting for IMS voice and SMS registration', flush=True)
    wait_for(service, lambda: service.registration().get('state') == 2 and
             service.registration().get('features', 0) & 3 == 3, 120, stopped)
    print('Startup: LTE, IMS voice and SMS registered', flush=True)
