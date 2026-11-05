#!/usr/bin/env python3
"""decode complete observation records and replay counters without the RTL simulator."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re


# fail with a stable diagnostic that detector calibration can require exactly.
def require(condition, message):
    """reject the first incomplete or inconsistent observation."""
    if not condition:
        raise ValueError('TRACE_REPLAY_FAILED ' + message)


# derive bit offsets from the retained packed declarations, rejecting unfamiliar syntax.
def make_schema(package):
    """expand packed structures into named leaf fields with explicit bit positions."""
    raw=package.read_bytes()
    text=re.sub(r'/\*[\s\S]*?\*/|//[^\n]*','',raw.decode())
    widths={'logic':1,'bit':1}
    structs={}
    # the package enum widths are part of the serialized payload contract.
    for high,low,name in re.findall(r'typedef\s+enum\s+logic\s*\[(\d+):(\d+)\]\s*\{[^}]*\}\s*(\w+)\s*;',text):
        widths[name]=int(high)-int(low)+1
    # declarations are visited in package order so nested packet types already exist.
    for body,name in re.findall(r'typedef\s+struct\s+packed\s*\{([^}]+)\}\s*(\w+)\s*;',text):
        fields=[]
        # each declaration contributes one or more identically typed fields.
        for declaration in body.split(';'):
            declaration=declaration.strip()
            # trailing semicolons create an empty final segment.
            if not declaration:
                continue
            match=re.fullmatch(r'(\w+)\s*(?:\[(\d+):(\d+)\])?\s+([\w\s,]+)',declaration)
            require(match is not None,'unsupported packed declaration')
            kind,high,low,names=match.groups()
            require(kind in widths,'unknown packed type ' + kind)
            width=widths[kind]*(int(high)-int(low)+1 if high else 1)
            # individual names retain their declared most-significant-first order.
            for field in names.split(','):
                field=field.strip(); require(re.fullmatch(r'\w+',field) is not None,'invalid field name')
                fields.append({'name':field,'type':kind,'width':width})
        structs[name]=fields; widths[name]=sum(field['width'] for field in fields)
    require('observe_t' in structs,'missing observe_t declaration')
    leaves={}

    # recursion preserves SystemVerilog packed structure bit order exactly.
    def expand(kind,prefix,lsb):
        """assign absolute offsets to nested packed leaf fields."""
        cursor=lsb+widths[kind]
        # every nested field occupies the next lower contiguous bit range.
        for field in structs[kind]:
            cursor-=field['width']; name=prefix+field['name']
            # nested structures expand without losing their names or offsets.
            if field['type'] in structs:
                expand(field['type'],name+'.',cursor)
            # vectors and enums are terminal fields in the portable schema.
            else:
                leaves[name]={'lsb':cursor,'width':field['width']}
        require(cursor==lsb,'packed width mismatch')

    expand('observe_t','',0)
    return {'schema':'DRG5-OBS1','packed_bits':widths['observe_t'],
            'package_sha256':hashlib.sha256(raw).hexdigest(),'fields':leaves}


# source-independent decoding uses only the emitted schema and serialized payload.
def decode(row,schema):
    """return a flat dictionary containing every observation leaf."""
    require(isinstance(row.get('packed'),str),'missing packed payload')
    packed=int(row['packed'],16)
    require(packed>=0 and packed < 1<<schema['packed_bits'],'packed width overflow')
    return {name:(packed>>field['lsb'])&((1<<field['width'])-1) for name,field in schema['fields'].items()}


# a mandatory terminal record prevents an arbitrary valid prefix from passing as complete.
def replay(path,schema):
    """validate record continuity, architectural ownership and independent counter updates."""
    opener=gzip.open if path.suffix=='.gz' else open
    records=0; sequence=0; epoch=0; total_retired=0; traps=0; irqs=0; counter_reads=0; counter_writes=0
    cycle=instret=None; inhibit=5; previous_reset=True
    live=set(); next_uid=0; order=0; expected_pc=0
    registers=[None]*32; registers[0]=0
    buses={'i':None,'d':None}; transactions={'i':0,'d':0}
    footer=None
    # consume lines incrementally so long traces do not require a large host buffer.
    with opener(path,'rt') as stream:
        header=json.loads(next(stream))
        require(header.get('schema')==schema['schema'] and header.get('packed_bits')==schema['packed_bits'],'schema mismatch')
        # a complete stream has exactly one footer after all edge records.
        for line in stream:
            row=json.loads(line)
            require(footer is None,'records after footer')
            # terminal metadata is checked against the last actually decoded edge.
            if row.get('end') is True:
                footer=row; continue
            records+=1; require(row.get('edge')==records,'edge discontinuity')
            rec=decode(row,schema)
            require(rec['overflow']==0,'observation overflow')
            # readable columns must not contradict the complete packed payload.
            for key,field in [('valid','valid'),('sequence','sequence_id'),('epoch','epoch'),
                              ('retired_before','retired_before'),('retired_after','retired_after'),
                              ('terminal','terminal.valid'),('trap','terminal.trap')]:
                require(row.get(key)==rec[field],'readable metadata mismatch')
            # fixed-width hexadecimal columns preserve all counter and instruction bits.
            for key,field in [('cycle_before','cycle_before'),('cycle_after','cycle_after'),
                              ('instret_before','instret_before'),('instret_after','instret_after'),
                              ('pc','terminal.packet.pc'),('raw','terminal.packet.raw')]:
                require(int(row[key],16)==rec[field],'readable payload mismatch')
            reset=bool(rec['cold_reset'] or rec['hart_reset'])
            # only the initial isolated rearm record may be intentionally invalid.
            if records==1:
                require(not rec['valid'] and rec['cold_reset'] and rec['isolated'] and rec['sequence_id']==0,'initial capture rearm')
            # every subsequent edge has a unique, contiguous observer sequence.
            else:
                sequence+=1
                require(rec['valid'] and rec['sequence_id']==sequence,'sequence discontinuity')
                # reset episodes advance the epoch once, without resetting total retirement.
                if reset and not previous_reset:
                    epoch+=1
                require(rec['epoch']==epoch,'reset epoch discontinuity')
                require(rec['retired_before']==total_retired,'independent retirement total before edge')
                require((rec['cycle_before'],rec['instret_before'],rec['inhibit_before'])==(cycle,instret,inhibit),
                        'counter pre-state continuity')
            successful=bool(rec['terminal.valid'] and not rec['terminal.trap'])
            next_cycle=0 if reset else (rec['cycle_before']+int(not rec['debug_mode'] and not rec['debug_ebreak_entry'] and not (rec['inhibit_before']&1)))&((1<<64)-1)
            next_instret=0 if reset else (rec['instret_before']+int(successful and not rec['debug_mode'] and not rec['debug_ebreak_entry'] and not (rec['inhibit_before']&4)))&((1<<64)-1)
            next_inhibit=5 if reset else rec['inhibit_before']
            # architectural reset aborts live tokens while capture identity remains continuous.
            if reset:
                require(not rec['terminal.valid'] and not rec['irq'],'reset architectural exclusion')
                live.clear(); registers=[None]*32; registers[0]=0; expected_pc=0
                # only cold reset reuses CPU input and terminal identities.
                if rec['cold_reset']:
                    next_uid=0; order=0
            # ordinary edges reconstruct ownership and pre-write operand values.
            else:
                # input allocation is independent of eventual retirement or killing.
                if rec['input_accept']:
                    require(next_uid not in live,'duplicate input identity'); live.add(next_uid); next_uid+=1
                # killed identities cannot be consumed by a later architectural terminal.
                for stage in range(5):
                    if rec['kill_valid']>>stage&1:
                        uid=rec['kill_uid']>>(64*stage)&((1<<64)-1)
                        require(uid in live,'killed owner missing'); live.remove(uid)
                # every terminal records one oldest instruction and its original PC.
                if rec['terminal.valid']:
                    uid=rec['terminal.uid']
                    require(uid in live and uid==min(live),'terminal ownership or age')
                    require(rec['terminal.order']==order and rec['terminal.packet.pc']==expected_pc,'architectural terminal sequence')
                    live.remove(uid); order+=1; expected_pc=rec['terminal.next_pc']
                    # used operand values reconstruct from earlier architectural writes.
                    for operand in ['rs1','rs2']:
                        if rec['terminal.packet.'+operand+'_used']:
                            index=rec['terminal.packet.'+operand]
                            require(registers[index] is not None and registers[index]==rec['terminal.packet.'+operand+'_value'],
                                    'architectural operand reconstruction')
                    # a fault has no ordinary GPR or CSR effect and no instret increment.
                    if rec['terminal.trap']:
                        require(not rec['terminal.rd_write'] and not rec['terminal.csr_read'] and not rec['terminal.csr_write'],'trap effects suppressed')
                        traps+=1
                    # successful GPR updates are sufficient to reconstruct subsequent operands.
                    elif rec['terminal.rd_write']:
                        require(rec['terminal.rd']!=0,'x0 write'); registers[rec['terminal.rd']]=rec['terminal.value']
                    # encoded CSR access rules are checked without trusting suppression annotations.
                    raw=rec['terminal.packet.raw']
                    if successful and raw&0x7f==0x73 and (raw>>12&7) in [1,2,3,5,6,7]:
                        form=raw>>12&7; rd=raw>>7&31; rs=raw>>15&31; address=raw>>20
                        read=form%4!=1 or rd!=0; write=form%4==1 or rs!=0
                        require(rec['terminal.csr_read']==read and rec['terminal.csr_write']==write,'encoded CSR suppression')
                        require(address==rec['terminal.packet.csr_addr'],'CSR address reconstruction')
                        # counter and inhibit semantics are independent of the DUT's CSR preview.
                        values={0xb00:rec['cycle_before']&0xffffffff,0xb80:rec['cycle_before']>>32,
                                0xb02:rec['instret_before']&0xffffffff,0xb82:rec['instret_before']>>32,
                                0x320:rec['inhibit_before']}
                        if address in values:
                            old=values[address]; source=rs if form>=5 else rec['terminal.packet.rs1_value']
                            new=source if form%4==1 else old|source if form%4==2 else old&~source
                            new&=5 if address==0x320 else 0xffffffff
                            require(rec['terminal.csr_old']==(old if read else 0) and rec['terminal.csr_new']==(new if write else 0),
                                    'counter CSR pre-edge read and requested write')
                            counter_reads+=int(read); counter_writes+=int(write)
                            # explicit writes replace one half of the old value and suppress its increment.
                            if write:
                                if address==0xb00:
                                    next_cycle=(rec['cycle_before']&0xffffffff00000000)|new
                                elif address==0xb80:
                                    next_cycle=new<<32|(rec['cycle_before']&0xffffffff)
                                elif address==0xb02:
                                    next_instret=(rec['instret_before']&0xffffffff00000000)|new
                                elif address==0xb82:
                                    next_instret=new<<32|(rec['instret_before']&0xffffffff)
                                else:
                                    next_inhibit=new
                # interrupts change the boundary without creating an instruction terminal.
                if rec['irq']:
                    require(not rec['terminal.valid'] and rec['irq_pc']==expected_pc and rec['redirect'],'interrupt boundary reconstruction')
                    expected_pc=rec['redirect_pc']; irqs+=1
                # an external accepted flush may independently select a continuation.
                elif rec['redirect'] and not rec['terminal.valid']:
                    expected_pc=rec['redirect_pc']
                # settled stage identities must be exactly the surviving live set.
                stages=[rec['stage_uid']>>(64*stage)&((1<<64)-1) for stage in range(5) if rec['stages_after']>>stage&1]
                require(len(stages)==len(set(stages)) and set(stages)==live,'stage ownership reconstruction')
            total_retired+=int(successful)
            require(rec['retired_after']==total_retired,'independent retirement total after edge')
            require((rec['cycle_after'],rec['instret_after'],rec['inhibit_after'])==(next_cycle,next_instret,next_inhibit),
                    'counter update replay')
            require(not rec['fatal'] and not rec['i_fatal'],'fatal capture cannot qualify normal completion')
            cycle=next_cycle; instret=next_instret; inhibit=next_inhibit
            # each port is checked independently of architectural retirement.
            for port in ['i','d']:
                owner=buses[port]
                # qualified cold isolation closes the previous port epoch explicitly.
                if rec['cold_reset'] and rec['isolated']:
                    buses[port]=None; continue
                # an exposed request cannot vanish before the target accepts it.
                if owner is not None and not owner['accepted']:
                    require(rec[port+'_offer'],'lost '+port+' request offer')
                # a first offer owns its immutable descriptor, even with ready low.
                if rec[port+'_offer']:
                    descriptor=tuple(rec[port+field] for field in (['_addr','_tag','_parcels'] if port=='i' else
                                    ['_addr','_tag','_write','_wdata','_size','_strobes']))
                    if owner is None:
                        owner={'descriptor':descriptor,'accepted':False}
                    require(not owner['accepted'] and owner['descriptor']==descriptor,'stable '+port+' request owner')
                # accepted ownership survives until one matching response.
                if rec[port+'_accept']:
                    require(owner is not None and not owner['accepted'],'unique '+port+' acceptance'); owner['accepted']=True
                if rec[port+'_response']:
                    require(owner is not None and owner['accepted'] and rec[port+'_response_tag']==owner['descriptor'][1],
                            'unique '+port+' response owner')
                    owner=None; transactions[port]+=1
                buses[port]=owner
            previous_reset=reset
    require(footer is not None,'missing terminal footer')
    require(footer.get('edges')==records and footer.get('sequence')==sequence and footer.get('epoch')==epoch and
            footer.get('retired')==total_retired,'footer does not match complete records')
    require(not live and all(owner is None for owner in buses.values()),'capture ends with live ownership')
    return {'status':'passed','edges':records,'sequence':sequence,'epochs':epoch+1,'retired':total_retired,
            'traps':traps,'interrupts':irqs,'counter_csr_reads':counter_reads,'counter_csr_writes':counter_writes,
            'instruction_transactions':transactions['i'],'data_transactions':transactions['d'],
            'trace_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'packed_bits':schema['packed_bits']}


# the command can emit a portable schema and validate either plain or compressed captures.
def main():
    """run replay with explicit input and output paths."""
    parser=argparse.ArgumentParser()
    parser.add_argument('trace',type=Path)
    parser.add_argument('--package',type=Path,default=Path(__file__).resolve().parents[1]/'rtl/drg5_control_pkg.sv')
    parser.add_argument('--schema-out',type=Path)
    parser.add_argument('--result-out',type=Path)
    args=parser.parse_args(); schema=make_schema(args.package)
    # schema output is an independently inspectable record of every packed offset.
    if args.schema_out:
        args.schema_out.write_text(json.dumps(schema,indent=2)+'\n')
    result=replay(args.trace,schema)
    # a result is written only after continuity, event and counter checks all pass.
    if args.result_out:
        args.result_out.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,sort_keys=True))


# imports expose the same replay implementation without launching a command.
if __name__=='__main__':
    main()
