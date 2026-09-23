#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <Block.h>

// Keep the private recorded-owner registry in this test translation unit so
// completion ordering and allocator destruction can be exercised without GPU.
#include "d3dmetal-transport.mm"

#include <barrier>
#include <cstdlib>
#include <memory>
#include <thread>
#include <atomic>

using namespace yaagl::pso::d3dmetal;
namespace metalfx = yaagl::pso::metalfx;
namespace framegeneration = yaagl::pso::fsr::framegeneration;

static void requireAt(bool value, int line) {
    if (!value) {
        std::fprintf(stderr, "lease lifetime assertion failed at line %d\n", line);
        std::abort();
    }
}
#define require(value) requireAt((value), __LINE__)

@interface LeaseCommitOptions : NSObject {
    NSMutableArray* _handlers;
}
- (void)addFeedbackHandler:(void (^)(id))handler;
- (void)complete;
- (NSUInteger)handlerCount;
@end

@implementation LeaseCommitOptions
- (instancetype)init {
    self = [super init];
    if (self) _handlers = [NSMutableArray new];
    return self;
}
- (void)addFeedbackHandler:(void (^)(id))handler {
    id copied = [handler copy];
    [_handlers addObject:copied];
    [copied release];
}
- (void)complete {
    for (id handler in _handlers)
        ((void (^)(id))handler)(nil);
}
- (NSUInteger)handlerCount { return _handlers.count; }
- (void)dealloc {
    [_handlers release];
    [super dealloc];
}
@end

@interface LeaseCommitQueue : NSObject {
@public
    NSUInteger commits;
    const void* lastBuffer;
}
- (void)commit:(const void* const*)buffers count:(NSUInteger)count options:(id)options;
@end

@implementation LeaseCommitQueue
- (void)commit:(const void* const*)buffers count:(NSUInteger)count options:(id)options {
    require(options != nil && count == 1);
    ++commits;
    lastBuffer = buffers[0];
}
@end

@interface LeaseLegacyCommandBuffer : NSObject {
    void (^_handler)(id);
}
- (void)addCompletedHandler:(void (^)(id))handler;
- (void)complete;
- (NSUInteger)handlerCount;
@end

@implementation LeaseLegacyCommandBuffer
- (void)addCompletedHandler:(void (^)(id))handler {
    if (_handler) Block_release(_handler);
    _handler = Block_copy(handler);
}
- (void)complete {
    if (_handler) _handler(self);
}
- (NSUInteger)handlerCount { return _handler ? 1 : 0; }
- (void)dealloc {
    if (_handler) Block_release(_handler);
    [super dealloc];
}
@end

static std::unique_ptr<OwnerState> makeOwner() {
    std::array<UseEntry, kMaxResources> uses{};
    return std::make_unique<OwnerState>(PreparedWork{}, uses, 0, 1, 1);
}

static std::shared_ptr<ExecutionSlot> publish(OwnerState& owner, void* buffer,
                                                std::atomic<int>& destroyed,
                                                bool frameGeneration = false) {
    ExecutionSlot::Lease initial = frameGeneration
        ? ExecutionSlot::Lease{ExecutionLeaseFor<std::shared_ptr<const framegeneration::PreparedFrame>>{}}
        : ExecutionSlot::Lease{ExecutionLeaseFor<std::shared_ptr<const metalfx::PreparedFrame>>{}};
    auto slot = reserveExecutionSlot(owner, buffer, std::move(initial));
    auto lifetime = std::shared_ptr<int>(new int, [&destroyed](int* value) {
        delete value;
        ++destroyed;
    });
    {
        std::lock_guard<std::mutex> lock(slot->mutex);
        if (frameGeneration) {
            slot->lease = std::shared_ptr<const framegeneration::ExecutionLease>(
                lifetime, reinterpret_cast<const framegeneration::ExecutionLease*>(0x2));
        } else {
            slot->lease = std::shared_ptr<const metalfx::ExecutionLease>(
                lifetime, reinterpret_cast<const metalfx::ExecutionLease*>(0x1));
        }
    }
    return slot;
}

static void commit(LeaseCommitQueue* queue, LeaseCommitOptions* options, void* buffer) {
    const void* batch[] = {buffer};
    commitRecordedBatch(queue, @selector(commit:count:options:), batch, 1, options);
    require(queue->lastBuffer == buffer);
}

static void registerLegacyHandler(LeaseLegacyCommandBuffer* buffer,
                                  std::shared_ptr<ExecutionSlot> slot) {
    [reinterpret_cast<id<MTLCommandBuffer>>(buffer)
        addCompletedHandler:^(id<MTLCommandBuffer>) { slot->retire(); }];
}

int main() { @autoreleasepool {
    LeaseCommitQueue* queue = [LeaseCommitQueue new];
    void* a = reinterpret_cast<void*>(0x1000);
    void* b = reinterpret_cast<void*>(0x2000);
    int nativeCalls = 0;
    std::atomic<int> aDead{0}, bDead{0}, reusedDead{0}, abandonedDead{0};
    auto owner = makeOwner();
    auto first = publish(*owner, a, aDead);
    auto second = publish(*owner, b, bDead);
    first.reset();
    second.reset();

    LeaseCommitOptions* firstOptions = [LeaseCommitOptions new];
    int* nativeCallsPointer = &nativeCalls;
    [firstOptions addFeedbackHandler:^(id) { ++*nativeCallsPointer; }];
    commit(queue, firstOptions, a);
    require(firstOptions.handlerCount == 2 && aDead == 0 && bDead == 0);
    LeaseCommitOptions* secondOptions = [LeaseCommitOptions new];
    commit(queue, secondOptions, b);
    require(secondOptions.handlerCount == 1 && queue->commits == 2);

    // A buffer identity reused for a later submission must not be cleared by
    // the earlier completion, even when completions arrive out of order.
    auto reused = publish(*owner, a, reusedDead);
    reused.reset();
    LeaseCommitOptions* reusedOptions = [LeaseCommitOptions new];
    commit(queue, reusedOptions, a);
    [secondOptions complete];
    require(aDead == 0 && bDead == 1 && reusedDead == 0);
    [firstOptions complete];
    require(nativeCalls == 1 && aDead == 1 && reusedDead == 0);

    // The callback retains its exact slot without referring to the owner;
    // feature/allocator destruction can precede the delayed GPU feedback.
    owner.reset();
    require(reusedDead == 0);
    [reusedOptions complete];
    require(reusedDead == 1);
    [firstOptions release];
    [secondOptions release];
    [reusedOptions release];

    // Frame-generation leases use the same submitted-slot feedback boundary.
    std::atomic<int> fgDead{0};
    auto fgOwner = makeOwner();
    auto fgSlot = publish(*fgOwner, reinterpret_cast<void*>(0x3000), fgDead, true);
    fgSlot.reset();
    LeaseCommitOptions* fgOptions = [LeaseCommitOptions new];
    commit(queue, fgOptions, reinterpret_cast<void*>(0x3000));
    fgOwner.reset();
    require(fgDead == 0);
    [fgOptions complete];
    require(fgDead == 1);
    [fgOptions release];

    // A published lease on a failed/discarded command has no completion. The
    // allocator-owned fallback releases it, and unregisters the dead buffer.
    auto abandoned = makeOwner();
    auto partial = publish(*abandoned, b, abandonedDead);
    partial.reset();
    require(abandonedDead == 0);
    abandoned.reset();
    require(abandonedDead == 1);
    {
        std::lock_guard<std::mutex> lock(gPendingLock);
        require(gPending.empty());
    }

    // Concurrent feedback and owner destruction synchronize through slot and
    // store mutexes; callbacks never retain or dereference OwnerState.
    std::atomic<int> concurrentDead{0};
    auto concurrentOwner = makeOwner();
    auto concurrentSlot = publish(*concurrentOwner, a, concurrentDead);
    std::barrier start(3);
    unregisterSlot(concurrentSlot.get());
    std::thread completion([slot = concurrentSlot, &start] {
        start.arrive_and_wait();
        slot->retire();
    });
    std::thread allocatorReset([&concurrentOwner, &start] {
        start.arrive_and_wait();
        concurrentOwner.reset();
    });
    start.arrive_and_wait();
    completion.join();
    allocatorReset.join();
    concurrentSlot.reset();
    require(concurrentDead.load() == 1);

    // Legacy completion owns the slot independently of feature/allocator. An
    // unsubmitted command buffer keeps its lease until it is released because
    // it remains possible to submit that buffer later.
    std::atomic<int> legacyDead{0};
    auto legacyOwner = makeOwner();
    LeaseLegacyCommandBuffer* legacyBuffer = [LeaseLegacyCommandBuffer new];
    auto legacySlot = publish(*legacyOwner, legacyBuffer, legacyDead);
    registerLegacyHandler(legacyBuffer, legacySlot);
    std::weak_ptr<ExecutionSlot> legacyWeak = legacySlot;
    legacySlot.reset();
    legacyOwner.reset();
    require(legacyDead.load() == 0);
    [legacyBuffer release];
    require(legacyDead.load() == 1);
    require(legacyWeak.expired());

    // Submitted legacy work retires at completion, not at command-buffer
    // destruction, even after the allocator owner has gone away.
    std::atomic<int> legacyFgDead{0};
    auto legacyFgOwner = makeOwner();
    LeaseLegacyCommandBuffer* legacyFgBuffer = [LeaseLegacyCommandBuffer new];
    auto legacyFgSlot = publish(*legacyFgOwner, legacyFgBuffer, legacyFgDead, true);
    registerLegacyHandler(legacyFgBuffer, legacyFgSlot);
    legacyFgSlot.reset();
    legacyFgOwner.reset();
    require(legacyFgDead.load() == 0);
    require(legacyFgBuffer.handlerCount == 1);
    [legacyFgBuffer complete];
    require(legacyFgDead.load() == 1);
    [legacyFgBuffer release];
    require(legacyFgDead.load() == 1);
    {
        std::lock_guard<std::mutex> lock(gPendingLock);
        require(gPending.empty());
    }
    [queue release];
    std::fprintf(stderr, "TRANSPORT_LIFETIME_PASS\n");
    return 0;
}}
