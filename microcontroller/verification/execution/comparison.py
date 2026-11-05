#!/usr/bin/env python3
"""compare retirement with Sail and account for physical bus effects independently."""
import json
from pathlib import Path
import re


# stable diagnostics make deliberately damaged records useful detector controls.
def require(condition, reason):
    """reject incomplete or inconsistent execution evidence."""
    # the first mismatch is retained instead of hidden by later differences.
    if not condition:
        raise ValueError('ARCH_COMPARE_FAILED '+reason)


# physical bus observations are matched to terminal instructions, never inferred from them.
def read_dut(path, schema):
    """validate a complete trace and return decoded terminal records."""
    rows=[json.loads(line) for line in Path(path).read_text().splitlines()]
    require(rows[0].get('schema')=='DRG5-ARCH1','trace header')
    require(rows[-1].get('end') is True,'trace completeness')
    footer=rows[-1]; terminals=[]; sequence=0; cycle=0; expected_pc=0
    owners={'i':None,'d':None}; seen={'i':set(),'d':set()}; pending=[]
    accepts={'i':0,'d':0}; effects={'reads':0,'writes':0}; last_uid=None
    # every event has a continuous sequence and a monotonic sampled clock.
    for row in rows[1:-1]:
        sequence+=1
        require(row['sequence']==sequence and row['cycle']>=cycle,'event continuity')
        cycle=row['cycle']; event=row['event']
        # requests have one owner from first valid through response consumption.
        if event=='offer':
            bus=row['bus'];require(owners[bus] is None,'overlapping transaction')
            require(row['tag'] not in seen[bus],'reused transaction tag')
            seen[bus].add(row['tag']);owners[bus]=dict(row,accepted=False)
        # an effect belongs to exactly one previously exposed request.
        elif event=='accept':
            bus=row['bus'];owner=owners[bus]
            require(owner is not None and owner['tag']==row['tag'] and not owner['accepted'],'duplicate or unowned acceptance')
            owner.update(accepted=True,reply=row['reply'],status=row['status']);accepts[bus]+=1
            # the memory scoreboard retains each accepted D descriptor until its instruction terminates.
            if bus=='d':
                pending.append(owner)
                # destructive read and write counts come solely from physical acceptance.
                if owner['address']==0x40000020 and not owner['write'] and not owner['status']:
                    effects['reads']+=1
                # write effects remain observable even if a later terminal is lost.
                if owner['address']==0x40000024 and owner['write'] and not owner['status']:
                    effects['writes']+=1
        # accepted requests cannot vanish or respond more than once.
        elif event=='response':
            bus=row['bus'];owner=owners[bus]
            require(owner is not None and owner['accepted'] and owner['tag']==row['tag'],'unowned response')
            owner['responded']=True;owners[bus]=None
        # asynchronous boundaries have their own ordered PC transition.
        elif event=='irq':
            require(row['pc']==expected_pc,'interrupt boundary')
            expected_pc=row['next_pc']
        # terminal order, architectural PC and memory effects are checked independently.
        elif event=='terminal':
            packed=int(row['packed'],16)
            require(packed<1<<schema['packed_bits'],'packed trace width')
            item={name:(packed>>field['lsb'])&((1<<field['width'])-1) for name,field in schema['fields'].items()}
            require(item['valid']==1 and item['order']==len(terminals),'terminal order')
            require(last_uid is None or item['uid']>last_uid,'terminal identity')
            last_uid=item['uid']
            require(item['packet.pc']==expected_pc,'architectural PC sequence')
            expected_pc=item['next_pc']
            # every completed memory instruction must consume its own physical transaction.
            if item['packet.op'] in (1,2):
                address=item['packet.mem_addr'];write=item['packet.op']==2
                matched=pending and pending[0]['address']==address and pending[0]['write']==write
                # local rejected accesses have no request; successful operations always have one.
                if not item['trap'] or matched:
                    require(bool(matched),'missing or reordered memory effect')
                    owner=pending.pop(0)
                    require(owner.get('responded') and owner['size']==item['packet.mem_size'],'memory completion descriptor')
                    require(bool(owner['status'])==bool(item['trap']),'memory error precision')
                    # enabled bytes must equal the instruction's original store data.
                    if write:
                        width=1<<owner['size'];lane=address&3;mask=(1<<(width*8))-1
                        require(owner['lanes']==((1<<width)-1)<<lane and
                                owner['data']==item['packet.mem_wdata'] and
                                owner['data']==(item['packet.rs2_value']&mask)<<(lane*8),'store payload')
            terminals.append(item)
        # unknown records must not silently weaken the parser.
        else:
            require(False,'unknown event')
    require(sequence==footer['events'],'footer event count')
    require(not pending and all(owner is None for owner in owners.values()),'unfinished physical transaction')
    require(accepts['i']==footer['i_accepts'] and accepts['d']==footer['d_accepts'],'acceptance totals')
    require(effects['reads']==footer['mmio_reads'] and effects['writes']==footer['mmio_writes'],'physical MMIO totals')
    require(sum(not item['trap'] for item in terminals)==footer['retired'] and
            sum(item['trap'] for item in terminals)==footer['traps'],'terminal totals')
    return terminals,footer


# the independent Sail text trace supplies instruction, register, memory and trap expectations.
def read_sail(path):
    """parse pinned Sail 0.16 traces without consulting DUT results."""
    result=[];current=None
    # only explicitly recognized architectural events participate in comparison.
    for line in Path(path).read_text().splitlines():
        instruction=re.match(r'\[(\d+)\] \[M\]: 0x([0-9A-Fa-f]+) \(0x([0-9A-Fa-f]+)\)',line)
        # instruction sequence numbers detect a missing reference record.
        if instruction:
            index,pc,raw=instruction.groups();require(int(index)==len(result),'Sail instruction sequence')
            current={'pc':int(pc,16),'raw':int(raw,16),'length':len(raw)//2,'gpr':[], 'csr':[], 'memory':[], 'trap':False}
            result.append(current);continue
        # boot diagnostics and fetch parcels precede the first instruction record.
        if current is None:
            continue
        register=re.fullmatch(r'x(\d+) <- 0x([0-9A-Fa-f]+)',line)
        # x0 updates are architecturally suppressed even if a reference prints them.
        if register and int(register[1]):
            current['gpr'].append((int(register[1]),int(register[2],16)))
        csr=re.fullmatch(r'CSR \w+ \(0x([0-9A-Fa-f]+)\) (->|<-) 0x([0-9A-Fa-f]+)',line)
        # trap-induced CSR changes remain separate from explicit CSR instructions.
        if csr:
            current['csr'].append((int(csr[1],16),csr[2],int(csr[3],16)))
        memory=re.fullmatch(r'mem\[([RW]),0x([0-9A-Fa-f]+)\] (?:->|<-) 0x([0-9A-Fa-f]+)',line)
        # fetch accesses are excluded; data accesses retain their width and value.
        if memory:
            current['memory'].append((memory[1],int(memory[2],16),len(memory[3])//2,int(memory[3],16)))
        # each synchronous exception must expose machine trap state in this trace mode.
        if line.startswith('trapping '):
            current['trap']=True
    require(bool(result),'empty Sail execution')
    return result


# stop labels define the exact reference boundary before platform-specific MMIO self-checks.
def compare(dut,reference,stop_pc):
    """compare every terminal in the reference program, including trapping instructions."""
    require(len(dut)>=32+len(reference)+1,'missing DUT reference body')
    # real reset ROM initialization is checked rather than silently discarded.
    for index,item in enumerate(dut[:32]):
        require(item['packet.pc']==index*4 and not item['trap'],'boot execution')
        # x1 through x31 are deliberately initialized by instructions, not reset assumptions.
        if index<31:
            require(item['rd_write']==1 and item['rd']==index+1 and item['value']==0,'boot register initialization')
    counts={'instructions':len(reference),'traps':0,'register_writes':0,'csr_accesses':0,'memory_accesses':0,
            'compressed':0,'straddled':0}
    # sequential alignment exposes missing, duplicated or stale-path instructions immediately.
    for index,(actual,expected) in enumerate(zip(dut[32:],reference)):
        label=f' at instruction {index} pc={expected["pc"]:#x}'
        require((actual['packet.pc'],actual['packet.raw'],actual['packet.length'])==
                (expected['pc'],expected['raw'],expected['length']),'instruction identity'+label)
        next_pc=reference[index+1]['pc'] if index+1<len(reference) else stop_pc
        require(actual['next_pc']==next_pc,'next PC'+label)
        require(bool(actual['trap'])==expected['trap'],'trap disposition'+label)
        gpr=[(actual['rd'],actual['value'])] if actual['rd_write'] else []
        require(gpr==expected['gpr'],'register result'+label)
        counts['register_writes']+=len(gpr);counts['traps']+=expected['trap']
        counts['compressed']+=expected['length']==2
        counts['straddled']+=expected['length']==4 and expected['pc']%4==2
        # synchronous trap metadata comes from reference machine state updates.
        if expected['trap']:
            writes={address:value for address,direction,value in expected['csr'] if direction=='<-'}
            require(writes.get(0x341)==actual['packet.pc'] and writes.get(0x342)==actual['packet.cause'] and
                    writes.get(0x343)==actual['packet.mtval'],'machine trap state'+label)
        # explicit CSR operations compare suppressed access flags as well as values.
        elif actual['packet.op']==3:
            address=actual['packet.csr_addr']
            reads=[value for addr,direction,value in expected['csr'] if addr==address and direction=='->']
            writes=[value for addr,direction,value in expected['csr'] if addr==address and direction=='<-']
            operation=(expected['raw']>>12)&7;source=(expected['raw']>>15)&31;destination=(expected['raw']>>7)&31
            read_expected=destination!=0 if operation in (1,5) else True
            write_expected=True if operation in (1,5) else source!=0
            require(bool(actual['csr_read'])==read_expected and bool(actual['csr_write'])==write_expected,'CSR suppression'+label)
            # Sail CSR exchanges report their old value through the destination, without a read log.
            if read_expected and not reads and destination:
                reads=[value for register,value in expected['gpr'] if register==destination]
            require(bool(reads)==read_expected and bool(writes)==write_expected,'Sail CSR observation'+label)
            require(not reads or reads==[actual['csr_old']],'CSR read value'+label)
            require(not writes or writes==[actual['csr_new']],'CSR write value'+label)
            counts['csr_accesses']+=len(reads)+len(writes)
        # successful data transactions also compare independent reference address and transferred bytes.
        if expected['memory']:
            require(len(expected['memory'])==1 and actual['packet.op'] in (1,2),'reference memory operation'+label)
            kind,address,width,value=expected['memory'][0]
            require(address==actual['packet.mem_addr'] and width==1<<actual['packet.mem_size'] and
                    (kind=='W')==(actual['packet.op']==2),'reference memory descriptor'+label)
            actual_value=actual['packet.rs2_value'] if kind=='W' else actual['packet.result']
            require(actual_value&((1<<(8*width))-1)==value,'reference memory value'+label)
            counts['memory_accesses']+=1
    require(dut[32+len(reference)]['packet.pc']==stop_pc,'reference stop boundary')
    return counts
