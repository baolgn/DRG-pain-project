#!/usr/bin/env python3
"""explore abstract CDC/reset protocols and retain reachable counterexamples."""

import argparse
from collections import deque
from dataclasses import asdict, dataclass, replace
import hashlib
import json
from pathlib import Path
import sys


def require(condition, message):
    """keep every safety predicate active under optimized Python."""
    # failed invariants stop the campaign with their shortest observed trace.
    if not condition:
        raise ValueError(message)


def explore(initial, successors, invariant, expect_failure=False):
    """visit every reachable state of one finite abstract protocol."""
    todo = deque([initial])
    parents = {initial: None}
    actions = {}
    transitions = 0
    failure = None
    # arbitrary interleavings include delayed or temporarily stopped endpoints.
    while todo:
        state = todo.popleft()
        # each state is checked before any successor can hide its violation.
        try:
            invariant(state)
        # retain the shortest trace because the search is breadth first.
        except ValueError as error:
            failure = {'property': str(error), 'trace': []}
            cursor = state
            # the initial state and every action remain available for replay.
            while parents[cursor] is not None:
                previous, action = parents[cursor]
                failure['trace'].append({'action': action, 'state': asdict(cursor)})
                cursor = previous
            failure['trace'].append({'action': 'initial', 'state': asdict(cursor)})
            failure['trace'].reverse()
            break
        # finite identity bounds make full reachable-state exhaustion possible.
        for action, following in successors(state):
            transitions += 1
            actions[action] = actions.get(action, 0) + 1
            # revisiting a state adds no new safety behavior, including stutter.
            if following not in parents:
                parents[following] = (state, action)
                todo.append(following)
    require((failure is not None) == expect_failure,
            'missing negative-control failure' if expect_failure else str(failure))
    return {'states': len(parents), 'transitions': transitions, 'action_counts': actions,
            'exhausted': failure is None, 'expected_failure': expect_failure,
            'counterexample': failure}


@dataclass(frozen=True)
class Mailbox:
    """retain both handshake endpoints and the completion sink through CPU reset."""

    phase: int = 0
    req: int = 0
    ack: int = 0
    req_sync: tuple = (0, 0)
    ack_sync: tuple = (0, 0)
    payload: tuple = (0, 0)
    reply: tuple = (0, 0)
    completion: tuple = (0, 0)
    next_id: int = 1
    cpu_reset: bool = False
    stop: bool = False
    offered: tuple = ()
    admitted: tuple = ()
    executed: tuple = ()
    responses: tuple = ()
    consumed: tuple = ()


def mailbox_edges(state):
    """interleave source edges, destination edges and reset observations."""
    yield 'CPU reset asserted', replace(state, cpu_reset=True, stop=True)
    yield 'CPU reset released', replace(state, cpu_reset=False)
    yield 'STOP observed', replace(state, stop=True)
    source = replace(state, ack_sync=(state.ack, state.ack_sync[0]))
    # the request and payload remain exposed until the retained endpoint sees ack.
    if state.phase == 1 and state.ack_sync[1]:
        source = replace(source, req=0, phase=2, completion=state.reply,
                         responses=state.responses + (state.reply[0],))
    # payload reuse waits for the full return-to-zero handshake.
    elif state.phase == 2 and not state.ack_sync[1]:
        source = replace(source, phase=3)
    yield 'source edge', source
    destination = replace(state, req_sync=(state.req, state.req_sync[0]))
    # one high request causes one capture; ack prevents recapture while held high.
    if state.req_sync[1] and not state.ack:
        token = state.payload[0]
        executed = state.executed if state.stop or state.cpu_reset else state.executed + (token,)
        destination = replace(destination, ack=1, reply=state.payload,
                              admitted=state.admitted + (token,), executed=executed)
    # the reply remains stable while the source completes return-to-zero.
    elif not state.req_sync[1] and state.ack:
        destination = replace(destination, ack=0)
    yield 'destination edge', destination
    # a new operation needs an empty retained sink, not merely a running CPU.
    if state.phase == 0 and not state.cpu_reset and state.next_id <= 2:
        token = state.next_id
        payload = (token, 0x13579BDF ^ (token * 0x1020304))
        yield 'offer coherent command', replace(state, phase=1, req=1, payload=payload,
                next_id=token + 1, offered=state.offered + (token,))
    # software consumption is distinct from receipt by the retained bridge.
    if state.phase == 3 and not state.cpu_reset:
        yield 'consume retained completion', replace(state, phase=0, payload=(0, 0),
                completion=(0, 0), consumed=state.consumed + (state.completion[0],))


def check_mailbox(state):
    """reject duplicated, unoffered or incoherent command acknowledgments."""
    require(len(set(state.admitted)) == len(state.admitted), 'duplicate command admission')
    require(len(set(state.responses)) == len(state.responses), 'duplicate command response')
    require(len(set(state.consumed)) == len(state.consumed), 'duplicate completion consumption')
    require(set(state.admitted) <= set(state.offered), 'unoffered command admitted')
    require(set(state.executed) <= set(state.admitted), 'unadmitted command executed')
    require(set(state.responses) <= set(state.admitted), 'phantom command response')
    require(set(state.consumed) <= set(state.responses), 'phantom completion consumption')
    # a pending reply must retain every payload bit and the original identity.
    if state.phase in (2, 3):
        require(state.completion == state.payload, 'torn or stale command completion')
    # idle permits require the complete handshake baseline, even after CPU reset.
    if state.phase == 0:
        require(state.req == 0 and state.ack_sync[1] == 0, 'idle before handshake baseline')


def gray(value):
    """encode one pointer with one changing bit per increment."""
    return value ^ (value >> 1)


def binary(value):
    """decode the model's coherent two-bit Gray pointer sample."""
    return value ^ (value >> 1)


@dataclass(frozen=True)
class RecordFifo:
    """model two whole-record entries and one coordinated link replacement."""

    mode: str = 'online'
    writer_ready: bool = True
    reader_ready: bool = True
    epoch: int = 1
    write_pointer: int = 0
    read_pointer: int = 0
    write_sync: tuple = (0, 0)
    read_sync: tuple = (0, 0)
    memory: tuple = ((0, 0), (0, 0))
    next_id: int = 1
    offered: tuple = ()
    queued: tuple = ()
    delivered: tuple = ()
    discarded: tuple = ()
    unsafe_reset_used: bool = False


def fifo_edges(state, unsafe=False):
    """interleave pointer crossings, complete-record transfers and reset phases."""
    writer = replace(state, read_sync=(gray(state.read_pointer), state.read_sync[0]))
    reader = replace(state, write_sync=(gray(state.write_pointer), state.write_sync[0]))
    yield 'writer clock edge', writer
    yield 'reader clock edge', reader
    # admission is closed before either endpoint is allowed to clear a pointer.
    if state.mode == 'online':
        full = (state.write_pointer - binary(state.read_sync[1])) % 4 == 2
        empty = state.read_pointer == binary(state.write_sync[1])
        # only complete tagged records enter this atomic FIFO abstraction.
        if not full and state.next_id <= 5:
            token = (state.epoch, state.next_id)
            memory = list(state.memory)
            memory[state.write_pointer % 2] = token
            following = (state.write_pointer + 1) % 4
            require((gray(following) ^ gray(state.write_pointer)).bit_count() == 1,
                    'writer pointer is not Gray adjacent')
            yield 'write complete record', replace(writer, write_pointer=following,
                    memory=tuple(memory), next_id=state.next_id + 1,
                    offered=state.offered + (token,), queued=state.queued + (token,))
        # stale synchronized pointers may delay a read but must not expose old cells.
        if not empty:
            token = state.memory[state.read_pointer % 2]
            following = (state.read_pointer + 1) % 4
            require((gray(following) ^ gray(state.read_pointer)).bit_count() == 1,
                    'reader pointer is not Gray adjacent')
            yield 'read complete record', replace(reader, read_pointer=following,
                    queued=state.queued[1:], delivered=state.delivered + (token,))
        # two distinct link identities are enough to exercise stale retained cells.
        if state.epoch == 1:
            yield 'request bilateral isolation', replace(state, mode='isolating')
        # this deliberate defect resets only the reader while its peer remains live.
        if unsafe and not state.unsafe_reset_used:
            yield 'unsafe one-sided reader reset', replace(state, read_pointer=0,
                    unsafe_reset_used=True)
    # each reset endpoint confirms isolation before shared reinitialization.
    elif state.mode == 'isolating':
        yield 'writer isolation confirmed', replace(state, writer_ready=False)
        yield 'reader isolation confirmed', replace(state, reader_ready=False)
        # reset both pointers and synchronizers only after both confirms are retained.
        if not state.writer_ready and not state.reader_ready:
            yield 'clear both isolated endpoints', replace(state, mode='joining', epoch=2,
                    write_pointer=0, read_pointer=0, write_sync=(0, 0), read_sync=(0, 0),
                    queued=(), discarded=state.discarded + state.queued)
    # reset release and ready exchange cannot themselves create data or acceptance.
    elif state.mode == 'joining':
        yield 'writer ready confirmed', replace(state, writer_ready=True)
        yield 'reader ready confirmed', replace(state, reader_ready=True)
        # rejoin is a coordinator decision, not one endpoint's local reset release.
        if state.writer_ready and state.reader_ready:
            yield 'open new link identity', replace(state, mode='online')


def check_fifo(state, structural=True):
    """account every accepted record exactly once without stale-cell delivery."""
    require(len(set(state.delivered)) == len(state.delivered), 'duplicate record from stale FIFO cell')
    require(set(state.delivered) <= set(state.offered), 'unoffered FIFO record')
    require(set(state.discarded).isdisjoint(state.delivered), 'discarded record delivered after reset')
    require(set(state.queued).isdisjoint(state.delivered), 'delivered record remains queued')
    # positive runs also compare the physical pointer relation with ghost ownership.
    if structural:
        require(len(state.queued) <= 2, 'FIFO overflow')
        require((state.write_pointer - state.read_pointer) % 4 == len(state.queued),
                'FIFO pointers disagree with owned records')
        require(set(state.offered) == set(state.queued + state.delivered + state.discarded),
                'FIFO record vanished without disposition')
        # an online link cannot be enabled by one locally ready endpoint.
        if state.mode == 'online':
            require(state.writer_ready and state.reader_ready, 'one-sided FIFO admission')


@dataclass(frozen=True)
class Ownership:
    """retain one allocation and an exposed transaction across reset and timeout."""

    owner: str = 'capture'
    transaction: str = 'none'
    cpu_reset: bool = False
    engine_reset: bool = False
    published: bool = False
    lease: bool = False
    contained: bool = False
    retirement_cleared: bool = False
    generation: int = 1


def ownership_edges(state, unsafe=False):
    """keep timeout, response, containment, lease release and reuse distinct."""
    yield 'CPU reset asserted', replace(state, cpu_reset=True)
    yield 'CPU reset released', replace(state, cpu_reset=False)
    reset_owner = 'quarantine' if state.owner == 'capture' else state.owner
    yield 'acquisition reset asserted', replace(state, engine_reset=True, owner=reset_owner)
    # exposing ready/valid commits the retained bridge to complete or contain it.
    if state.owner == 'capture' and state.transaction == 'none' and not state.engine_reset:
        yield 'expose memory request', replace(state, transaction='offered')
    # reset and timeout cannot withdraw a request already exposed to the fabric.
    if state.transaction == 'offered':
        yield 'memory request accepted', replace(state, transaction='accepted')
    # a late matching reply retires the old transaction, not the old quarantine.
    if state.transaction == 'accepted':
        yield 'matching memory response', replace(state, transaction='responded')
    # no elapsed-time observation certifies absence of future effects.
    if state.transaction in ('offered', 'accepted') and state.owner == 'capture':
        yield 'transaction timeout', replace(state, owner='quarantine')
    # the fabric's positive containment acknowledgment is independently authoritative.
    if state.owner == 'quarantine' and not state.contained:
        yield 'positive containment confirmed', replace(state, contained=True, transaction='contained')
    # an unpublished quarantined allocation is reclaimed only after positive resolution.
    if state.owner == 'quarantine' and (state.contained or state.transaction in ('none', 'responded')):
        yield 'reconcile quarantined allocation', replace(state, owner='retiring')
    # publication follows successful completed writes and cannot follow engine reset.
    if state.owner == 'capture' and state.transaction == 'responded' and not state.engine_reset:
        yield 'publish completed block', replace(state, owner='published', published=True)
    # the only lease in this finite model has the full current session/index/generation key.
    if state.owner == 'published' and not state.lease:
        yield 'acquire matching lease', replace(state, lease=True)
        yield 'begin unleased retirement', replace(state, owner='retiring')
    # a valid release ends only its own lease and does not free the allocation.
    if state.lease:
        yield 'release matching lease', replace(state, lease=False, owner='retiring')
    yield 'reject stale lease key', state
    # every reuse waits for the retirement clear to become globally visible.
    if state.owner == 'retiring' and not state.lease:
        yield 'retirement clear acknowledged', replace(state, owner='free', published=False,
                retirement_cleared=True, generation=2)
    # this defect treats an arbitrary release token as authority to free live storage.
    if unsafe and state.owner != 'free':
        yield 'unsafe stale lease frees allocation', replace(state, owner='free', generation=2)


def check_ownership(state):
    """reject publication or ownership changes without their positive prerequisites."""
    # free storage has no outstanding request, live lease or unretired publication.
    if state.owner == 'free':
        require(state.retirement_cleared, 'unowned release fabricated free allocation')
        require(state.transaction in ('none', 'responded', 'contained'), 'free allocation has outstanding access')
        require(not state.lease and not state.published, 'free allocation retains lease or publication')
    # publication may survive reset, but its successful transaction must remain known.
    if state.published:
        require(state.transaction == 'responded', 'publication without completed memory writes')
    # a reset cannot change the ownership generation or manufacture a completed clear.
    require((state.generation == 2) == (state.owner == 'free'), 'generation changed before retired reuse')


@dataclass(frozen=True)
class Stop:
    """separate trigger inhibition from frame resolution and terminal closure."""

    running: bool = True
    requested: bool = False
    inhibited: bool = False
    inhibit_ack: bool = False
    closed: bool = False
    closure_ack: bool = False
    cpu_reset: bool = False
    engine_reset: bool = False
    due_used: bool = False
    slots: tuple = ()
    triggers: tuple = ()
    records: tuple = ()
    pending: bool = False
    work: bool = False


def stop_edges(state, unsafe=False):
    """enumerate a due edge, reset, matching result, drain and acknowledgment races."""
    yield 'request or join STOP', replace(state, requested=True)
    yield 'CPU reset observed', replace(state, cpu_reset=True, requested=True)
    yield 'CPU reset released', replace(state, cpu_reset=False)
    # abrupt engine reset isolates the link; it cannot synthesize a closure reply.
    yield 'acquisition reset observed', replace(state, engine_reset=True, running=False,
            inhibited=True, pending=False, inhibit_ack=False, closure_ack=False)
    # a controlled stop is observed at an acquisition edge and never rearms on release.
    if state.requested and not state.engine_reset:
        yield 'observe stop on idle acquisition edge', replace(state, running=False, inhibited=True)
    # one symbolic due edge represents the ordering of every periodic slot.
    if state.running and not state.due_used and not state.engine_reset:
        # stop/reset has priority over a simultaneous due conversion trigger.
        if state.requested or state.cpu_reset:
            yield 'due edge inhibited', replace(state, due_used=True, running=False, inhibited=True,
                    slots=(1,), records=((1, 'placeholder'),), work=True)
        # an admitted trigger reserves exactly one matching future result.
        else:
            yield 'due edge triggers conversion', replace(state, due_used=True, slots=(1,),
                    triggers=(1,), pending=True)
    # a matching in-flight frame may finish after normal trigger inhibition.
    if state.pending and not state.engine_reset:
        yield 'matching frame resolved', replace(state, pending=False, records=((1, 'captured'),), work=True)
    yield 'reject unmatched frame result', state
    # positive drain completion is separate from request receipt and inhibition.
    if state.work and not state.engine_reset:
        yield 'record work positively resolved', replace(state, work=False)
    # inhibition is acknowledged only for an existing request on the live endpoint.
    if state.requested and state.inhibited and not state.engine_reset:
        yield 'acknowledge trigger inhibition', replace(state, inhibit_ack=True)
    # terminal closure cannot be inferred from an idle pin while work remains.
    if state.inhibited and not state.pending and not state.work and not state.engine_reset:
        yield 'seal terminal closure', replace(state, closed=True)
    # closure acknowledgment carries a different meaning from trigger inhibition.
    if state.closed and state.requested and not state.engine_reset:
        yield 'acknowledge terminal closure', replace(state, closure_ack=True)
    # this defect acknowledges a stop from reset state rather than accepted identity.
    if unsafe:
        yield 'unsafe reset default acknowledges STOP', replace(state, closure_ack=True)


def check_stop(state):
    """require an actual slot, trigger or accepted stop for each visible outcome."""
    require(set(state.triggers) <= set(state.slots), 'phantom conversion trigger')
    require({slot for slot, _ in state.records} <= set(state.slots), 'phantom scheduled record')
    require({slot for slot, kind in state.records if kind == 'captured'} <= set(state.triggers),
            'captured record without matching trigger')
    require(not state.inhibited or not state.running, 'inhibited engine still running')
    require(not state.inhibit_ack or state.requested and state.inhibited, 'phantom inhibition acknowledgment')
    require(not state.closure_ack or state.requested and state.closed and not state.pending and not state.work,
            'phantom or premature closure acknowledgment')
    require(not state.engine_reset or not state.inhibit_ack and not state.closure_ack,
            'reset manufactured a live acknowledgment')


@dataclass(frozen=True)
class Toggle:
    """exhibit why unilateral reset cannot be decoded as a toggle response."""

    acknowledgment: int = 1
    remembered: int = 1
    outstanding: bool = False
    delivered: bool = False


def toggle_edges(state):
    """allow reset before or after a consumer samples the response toggle."""
    yield 'reset remote acknowledgment toggle', replace(state, acknowledgment=0)
    # the deliberately broken consumer treats any difference as a completion.
    if state.acknowledgment != state.remembered:
        yield 'decode toggle difference as reply', replace(state, remembered=state.acknowledgment,
                delivered=True)


def check_toggle(state):
    """require a real outstanding operation for every response."""
    require(not state.delivered or state.outstanding, 'reset toggle created phantom response')


def main():
    """retain model scope, exhaustive results and deliberate broken-control traces."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    source = Path(__file__).resolve()
    source_bytes = source.read_bytes()
    (args.output / source.name).write_bytes(source_bytes)
    result = {'schema': 'DRG5-LIFECYCLE-MODEL-1', 'status': 'started',
              'source_sha256': hashlib.sha256(source_bytes).hexdigest(),
              'hardware_exercised': False, 'rtl_verified': False, 'physical_cdc_qualified': False,
              'scope': ['finite abstract state exploration, not an RTL or analog CDC proof',
                        'two commands; retained endpoints and response sink; arbitrary CPU-reset interleavings',
                        'depth-two FIFO; five records; one coordinated replacement across two link identities',
                        'one memory allocation/transaction/lease; timeout does not grant containment',
                        'one symbolic scheduled slot; controlled STOP versus abrupt acquisition reset',
                        'coherent Gray-pointer samples and stable bundled data are assumed physical obligations',
                        'state exhaustion proves safety only for these finite abstractions; no fairness or deadline proof'],
              'positive': {}, 'negative_controls': {}}
    code = 0
    # a model defect retains completed families and the exception instead of deleting evidence.
    try:
        result['positive']['retained_mailbox'] = explore(Mailbox(), mailbox_edges, check_mailbox)
        result['positive']['record_fifo'] = explore(RecordFifo(), fifo_edges, check_fifo)
        result['positive']['ownership'] = explore(Ownership(), ownership_edges, check_ownership)
        result['positive']['stop'] = explore(Stop(), stop_edges, check_stop)
        result['negative_controls']['one_sided_fifo_reset'] = explore(RecordFifo(),
                lambda state: fifo_edges(state, unsafe=True),
                lambda state: check_fifo(state, structural=False), expect_failure=True)
        result['negative_controls']['stale_lease_free'] = explore(Ownership(),
                lambda state: ownership_edges(state, unsafe=True), check_ownership, expect_failure=True)
        result['negative_controls']['unowned_stop_ack'] = explore(Stop(),
                lambda state: stop_edges(state, unsafe=True), check_stop, expect_failure=True)
        result['negative_controls']['reset_toggle_ack'] = explore(Toggle(), toggle_edges,
                check_toggle, expect_failure=True)
        require(source.read_bytes() == source_bytes, 'model source changed during campaign')
        result['status'] = 'abstract-lifecycle-safety-pass'
    # optimized Python preserves all rejection checks because none use assert.
    except Exception as error:
        result.update({'status': 'failed', 'error_type': type(error).__name__, 'error': str(error)})
        code = 1
    result['states_explored'] = sum(item['states'] for item in result['positive'].values())
    result['transitions_explored'] = sum(item['transitions'] for item in result['positive'].values())
    (args.output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'status': result['status'], 'states': result['states_explored'],
                      'transitions': result['transitions_explored'], 'error': result.get('error')}))
    return code


# run offline protocol exploration without reading ADC pins or programming hardware.
if __name__ == '__main__':
    sys.exit(main())
