#include "frame-probe-core.hpp"
#include <cassert>
#include <iostream>
#include <thread>
#include <vector>
using namespace yaagl::pso::frameprobe;
Record make(std::uint64_t id) { Record r;r.id=id;r.evaluation.id=id+100;r.scaler=0x1234;r.descriptor.width=2256;r.descriptor.height=1272;r.descriptor.jitterX=.25f;return r; }
int main() {
    static_assert(sizeof(Descriptor)==0x78);
    static_assert(offsetof(Descriptor,reset)==0x74);
    RecordLedger ledger(2);
    auto a=make(1),b=make(2),c=make(3);
    assert(!ledger.store(10,a).evicted);ledger.store(20,b);
    // Replay can be reordered across CPU threads: association is by record,
    // NOT a last-params global or latest-evaluation counter.
    auto rb=ledger.take(20,b.scaler,b.descriptor,false);assert(rb.match==RecordLedger::Match::Exact && rb.record->evaluation.id==102);
    auto ra=ledger.take(10,a.scaler,a.descriptor,false);assert(ra.match==RecordLedger::Match::Exact && ra.record->evaluation.id==101);
    assert(ledger.take(10,a.scaler,a.descriptor,false).match==RecordLedger::Match::Missing);
    ledger.store(10,a);auto changed=a.descriptor;changed.jitterX=-.25f;
    assert(ledger.take(10,a.scaler,changed,false).match==RecordLedger::Match::Changed);
    ledger.store(10,a);assert(ledger.take(10,0x9999,a.descriptor,false).match==RecordLedger::Match::Changed);
    ledger.store(10,a);assert(ledger.take(10,a.scaler,a.descriptor,true).match==RecordLedger::Match::Changed);
    ledger.store(10,a);assert(ledger.store(10,b).replaced);
    auto reused=ledger.take(10,b.scaler,b.descriptor,false);
    assert(reused.record->id==2 && reused.match==RecordLedger::Match::Reused);
    ledger.store(10,a);ledger.store(20,b);assert(ledger.store(30,c).evicted);
    assert(ledger.size()==2 && ledger.take(10,a.scaler,a.descriptor,false).match==RecordLedger::Match::Missing);
    // Bounded order index too; replacing an address does not grow a stale queue.
    for(unsigned i=0;i<100000;++i)ledger.store(20,b);
    assert(ledger.size()==2);
    RecordLedger concurrent(4096);std::vector<std::thread> workers;
    for(unsigned thread=0;thread<8;++thread)workers.emplace_back([&,thread]{
        for(unsigned i=0;i<1000;++i){auto r=make(10000*thread+i);auto key=thread+1;
            concurrent.store(key,r);auto x=concurrent.take(key,r.scaler,r.descriptor,r.forcedReset);
            assert(x.match==RecordLedger::Match::Exact && x.record->id==r.id);}
    });
    for(auto& w:workers)w.join();assert(concurrent.size()==0);
    std::cout<<"PASS: layout, immutable snapshot, reordered replay, repeated replay, changed bytes/scaler/reset, address reuse, bounded eviction, concurrent replay\n";
}
