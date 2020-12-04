import Combine
import NIO

public struct NIODispatchStatics {
    static var workerGroup = MultiThreadedEventLoopGroup(numberOfThreads: 8)
    static var serviceGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
}

public final class NIOPublisher<ID: Equatable, T>: Publisher {
    public enum Stage<ID, T> {
        case queued(ID, count: Int)
        case started(ID, count: Int)
        case completed(ID, count: Int, value: T)
    }

    private struct Progressable {
        let id: ID
        let future: EventLoopFuture<T>
    }

    public struct Queueable {
        let id: ID
        let future: (EventLoop) -> EventLoopFuture<T>
    }

    public typealias Output = Stage<ID, T>
    public typealias Failure = Never
    
    typealias Deliverable = (Output) -> Void
    typealias Completion = () -> Void

    private let maxQueued: Int
    private let maxInProgress: Int

    private var serviceLoop: EventLoop
    private var workerGroup: MultiThreadedEventLoopGroup
    private var input: AnyPublisher<Queueable, Never>

    private var queued: [Queueable] = []
    private var inProgress: [Progressable] = []
    private var completed: Int = 0
    private var canComplete = false
    private var requestsOutstanding: Int = 0

    private var delivery: Deliverable?
    private var completion: Completion?
    private var upstreamSubscription: Subscription?

    required init<P: Publisher>(
        _ publisher: P,
        serviceLoop: EventLoop? = .none,
        workerGroup: MultiThreadedEventLoopGroup = NIODispatchStatics.workerGroup,
        maxQueued: Int = 20,
        maxInProgress: Int = 8
    ) where P.Output == Queueable, P.Failure == Never {
        self.maxQueued = maxQueued
        self.maxInProgress = maxInProgress
        self.input = publisher.eraseToAnyPublisher()
        self.serviceLoop = serviceLoop ?? MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
        self.workerGroup = workerGroup
    }

    convenience init(
        _ queueables: [Queueable],
        serviceLoop: EventLoop? = .none,
        workerGroup: MultiThreadedEventLoopGroup = NIODispatchStatics.workerGroup,
        maxQueued: Int = 20,
        maxInProgress: Int = 8
    ) {
        self.init(
            queueables.publisher,
            serviceLoop: serviceLoop,
            workerGroup: workerGroup,
            maxQueued: maxQueued,
            maxInProgress: maxInProgress
        )
    }

    private func requestTopUp() {
        guard let subscription = self.upstreamSubscription, !canComplete else { return }
        let toRequest = Swift.max(
            0,
            (maxQueued + maxInProgress) - (self.queued.count + self.inProgress.count)
        )
        subscription.request(.max(toRequest))
        requestsOutstanding += toRequest
    }

    private func dispatchNextQueued() -> Void {
        if self.inProgress.count < self.maxInProgress {
            guard self.queued.count > 0 else { return }
            let dispatchable = self.queued.remove(at: 0)
            let future = dispatchable.future(self.workerGroup.next())
            let progressable = Progressable(id: dispatchable.id, future: future)
            progressable.future.hop(to: serviceLoop).whenSuccess(self.finish(progressable))
            self.inProgress.append(progressable)
            _ = self.delivery?(.started(progressable.id, count: self.inProgress.count))
        }
    }

    private func sendDownstream(_ id: ID, _ value: T) -> Void {
        completed += 1
        _ = delivery?(.completed(id, count: self.completed, value: value))
        inProgress = inProgress.filter { $0.id != id }
        dispatchNextQueued()
        requestTopUp()
    }

    private func finish(_ progressable: Progressable) -> (T) -> Void {
        { [weak self] (value) in
            guard let self = self else { return }
            self.sendDownstream(progressable.id, value)
            self.dispatchNextQueued()
            if self.canComplete && self.queued.count == 0 && self.inProgress.count == 0 {
                self.completion?()
            }
        }
    }

    private func handleUpstreamSubscription(_ subscription: Subscription) {
        self.serviceLoop.makeSucceededFuture(Void.self).whenSuccess { generator in
            self.upstreamSubscription = subscription
            self.requestTopUp()
        }
    }

    private func handleUpstreamValue(_ queueable: Queueable) -> Subscribers.Demand {
        self.serviceLoop.makeSucceededFuture(queueable).whenSuccess { [weak self] generator in
            guard let self = self else { return }
            self.queued.append(queueable)
            _ = self.delivery?(.queued(queueable.id, count: self.queued.count))
            self.dispatchNextQueued()
        }
        return .none
    }

    private func handleUpstreamCompletion(_ completion: Subscribers.Completion<Failure>) {
        self.serviceLoop.makeSucceededFuture(Void.self).whenSuccess { generator in
            self.canComplete = true
            if self.queued.count == 0 && self.inProgress.count == 0 {
                self.completion?()
            }
        }
    }

    public func receive<S>(subscriber: S) where S : Subscriber, Never == S.Failure, Output == S.Input {
        self.serviceLoop.makeSucceededFuture(Void.self).whenSuccess { generator in
            self.delivery = { t in _ = subscriber.receive(t) }
            self.completion = { subscriber.receive(completion: .finished) }
            self.input.subscribe(
                AnySubscriber<Queueable, Never>(
                    receiveSubscription: self.handleUpstreamSubscription,
                    receiveValue: self.handleUpstreamValue,
                    receiveCompletion: self.handleUpstreamCompletion
                )
            )
        }
    }
}
