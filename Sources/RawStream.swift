//
//  The MIT License (MIT)
//
//  Copyright (c) 2016 Srdan Rasic (@srdanrasic)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

// MARK: - _StreamType

/// Represents a stream over generic EventType.
public protocol _StreamType {

  /// The type of events generated by the stream.
  associatedtype Event: EventType

  /// Register an observer that will receive events from a stream.
  ///
  /// In case of pull-driven streams, e.g. `Stream<T>` or `Operation<T, E>`,
  /// this actually triggers event generation.
  @warn_unused_result
  func observe(observer: (Event) -> Void) -> Disposable
}

extension _StreamType {

  /// Register an observer that will receive elements from `.Next` events of the stream.
  @warn_unused_result
  public func observeNext(observer: (Event.Element) -> Void) -> Disposable {
    return observe { event in
      if let element = event.element {
        observer(element)
      }
    }
  }

  /// Register an observer that will be executed on `.Completed` event.
  @warn_unused_result
  public func observeCompleted(observer: () -> Void) -> Disposable {
    return observe { event in
      if event.isCompletion {
        observer()
      }
    }
  }
}

extension _StreamType where Event: Errorable {

  /// Register an observer that will receive error from `.Error` event of the stream.
  @warn_unused_result
  public func observeError(observer: (Event.ErrorType) -> Void) -> Disposable {
    return observe { event in
      if let error = event.error {
        observer(error)
      }
    }
  }
}

// MARK: - RawStreamType

/// Represents an underlying stream generalized over EventType and used by
/// higher-level implementations like `Stream<T>` or `Operation<T, E>`.
public protocol RawStreamType: _StreamType {
}

// MARK: - RawStream

/// An underlying stream generalized over EventType and used by
/// higher-level implementations like `Stream<T>` or `Operation<T, E>`.
public struct RawStream<Event: EventType>: RawStreamType {

  private let producer: (Observer<Event>) -> Disposable

  /// Create new `RawStream` given a producer closure.
  public init(producer: (Observer<Event>) -> Disposable) {
    self.producer = producer
  }

  /// Register an observer that will receive events from a stream.
  @warn_unused_result
  public func observe(observer: (Event) -> Void) -> Disposable {
    let serialDisposable = SerialDisposable(otherDisposable: nil)
    let lock = NSRecursiveLock(name: "observe")
    var terminated = false
    let observer = Observer<Event> { event in
      lock.atomic {
        guard !serialDisposable.isDisposed && !terminated else { return }
        if event.isTermination {
          terminated = true
          observer(event)
          serialDisposable.dispose()
        } else {
          observer(event)
        }
      }
    }
    serialDisposable.otherDisposable = producer(observer)
    return serialDisposable
  }
}

// MARK: - Extensions

public extension _StreamType {

  /// Transform a stream type into concrete `RawStream`.
  @warn_unused_result
  public func toRawStream() -> RawStream<Event> {
    return RawStream { observer in
      return self.observe(observer: observer.observer)
    }
  }
}

// MARK: Creation

public extension RawStream where Event.Element: Integer {

  /// Create a stream that emits an integer every `interval` time on a given queue.
  @warn_unused_result
  public static func interval(_ interval: TimeValue, queue: DispatchQueue) -> RawStream<Event> {
    return RawStream { observer in
      var number: Event.Element = 0
      var dispatch: (() -> Void)!
      let disposable = SimpleDisposable()
      dispatch = {
        queue.after(when: interval) {
          guard !disposable.isDisposed else { dispatch = nil; return }
          observer.next(number)
          number = number + 1
          dispatch()
        }
      }
      dispatch()
      return disposable
    }
  }
}

public extension RawStream {

  /// Create a stream that emits given elements after `time` time on a given queue.
  @warn_unused_result
  public static func timer(events: [Event], time: TimeValue, queue: DispatchQueue) -> RawStream<Event> {
    return RawStream { observer in
      let disposable = SimpleDisposable()
      queue.after(when: time) {
        guard !disposable.isDisposed else { return }
        events.forEach(observer.on)
      }
      return disposable
    }
  }
}

// MARK: Transformation

public extension RawStreamType {

  // WONTDO: buffer
  // WONTDO: flatMap

  /// Transform each element by applying `transform` on it.
  @warn_unused_result
  public func map<U: EventType>(_ transform: (Event) -> U) -> RawStream<U> {
    return RawStream<U> { observer in
      return self.observe { event in
        observer.observer(transform(event))
      }
    }
  }

  /// Apply `combine` to each element starting with `initial` and emit each 
  /// intermediate result. This differs from `reduce` which emits only final result.
  @warn_unused_result
  public func scan<U: EventType>(_ initial: U, _ combine: (U, Event) -> U) -> RawStream<U> {
    return RawStream<U> { observer in
      var accumulator = initial
      observer.observer(accumulator)
      return self.observe { event in
        accumulator = combine(accumulator, event)
        observer.observer(accumulator)
      }
    }
  }

  /// WONTDO: window
}

// MARK: Filtration

public extension RawStreamType {

  /// Emit an element only if `interval` time passes without emitting another element.
  @warn_unused_result
  public func debounce(interval: TimeValue, on queue: DispatchQueue) -> RawStream<Event> {
    return RawStream { observer in
      var timerSubscription: Disposable? = nil
      var previousEvent: Event? = nil
      return self.observe { event in
        timerSubscription?.dispose()
        if event.isTermination {
          if let previousEvent = previousEvent {
            observer.observer(previousEvent)
            observer.observer(event)
          }
        } else {
          previousEvent = event
          timerSubscription = queue.disposableAfter(when: interval) {
            if let _event = previousEvent {
              observer.observer(_event)
              previousEvent = nil
            }
          }
        }
      }
    }
  }

  /// Emit first element and then all elements that are not equal to their predecessor(s).
  @warn_unused_result
  public func distinct(areDistinct: (Event.Element, Event.Element) -> Bool) -> RawStream<Event> {
    return RawStream { observer in
      var lastElement: Event.Element? = nil
      return self.observe { event in
        if let element = event.element {
          if lastElement == nil || areDistinct(lastElement!, element) {
            observer.observer(event)
          }
          lastElement = element
        } else {
          observer.observer(event)
        }
      }
    }
  }

  /// Emit only element at given index if such element is produced.
  @warn_unused_result
  public func element(at index: Int) -> RawStream<Event> {
    return RawStream { observer in
      var currentIndex = 0
      return self.observe { event in
        if !event.isTermination {
          if currentIndex == index {
            observer.observer(event)
            observer.completed()
          } else {
            currentIndex += 1
          }
        } else {
          observer.observer(event)
        }
      }
    }
  }

  /// Emit only elements that pass `include` test.
  @warn_unused_result
  public func filter(include: (Event) -> Bool) -> RawStream<Event> {
    return RawStream { observer in
      return self.observe { event in
        if include(event) {
          observer.observer(event)
        }
      }
    }
  }

  /// Emit only the first element generated by the stream and then completes.
  @warn_unused_result
  public func first() -> RawStream<Event> {
    return take(first: 1)
  }

  /// Ignore all events that are not terminal events.
  @warn_unused_result
  public func ignoreElements() -> RawStream<Event> {
    return RawStream { observer in
      return self.observe { event in
        if event.isTermination {
          observer.observer(event)
        }
      }
    }
  }

  /// Emit only last element generated by the stream and then completes.
  @warn_unused_result
  public func last() -> RawStream<Event> {
    return take(last: 1)
  }

  /// Periodically sample the stream and emit latest element from each interval.
  @warn_unused_result
  public func sample(interval: TimeValue, on queue: DispatchQueue) -> RawStream<Event> {
    return RawStream { observer in

      let serialDisposable = SerialDisposable(otherDisposable: nil)
      var latestEvent: Event? = nil
      var dispatch: (() -> Void)!
      dispatch = {
        queue.after(when: interval) {
          guard !serialDisposable.isDisposed else { dispatch = nil; return }
          if let event = latestEvent {
            observer.observer(event)
            latestEvent = nil
          }
          dispatch()
        }
      }

      serialDisposable.otherDisposable = self.observe { event in
        latestEvent = event
        if event.isTermination {
          observer.observer(event)
          serialDisposable.dispose()
        }
      }

      dispatch()
      return serialDisposable
    }
  }

  /// Suppress first `count` elements generated by the stream.
  @warn_unused_result
  public func skip(first count: Int) -> RawStream<Event> {
    return RawStream { observer in
      var count = count
      return self.observe { event in
        if count > 0 {
          count -= 1
        } else {
          observer.observer(event)
        }
      }
    }
  }

  /// Suppress last `count` elements generated by the stream.
  @warn_unused_result
  public func skip(last count: Int) -> RawStream<Event> {
    guard count > 0 else { return self.toRawStream() }
    return RawStream { observer in
      var buffer: [Event] = []
      return self.observe { event in
        if event.isTermination {
          observer.observer(event)
        } else {
          buffer.append(event)
          if buffer.count > count {
            observer.observer(buffer.removeFirst())
          }
        }
      }
    }
  }

  /// Emit only first `count` elements of the stream and then complete.
  @warn_unused_result
  public func take(first count: Int) -> RawStream<Event> {
    return RawStream { observer in
      guard count > 0 else {
        observer.completed()
        return NotDisposable
      }

      var taken = 0

      let serialDisposable = SerialDisposable(otherDisposable: nil)
      serialDisposable.otherDisposable = self.observe { event in

        if let element = event.element {
          if taken < count {
            taken += 1
            observer.next(element)
          }

          if taken == count {
            observer.completed()
            serialDisposable.otherDisposable?.dispose()
          }
        } else {
          observer.observer(event)
        }
      }

      return serialDisposable
    }
  }

  /// Emit only last `count` elements of the stream and then complete.
  @warn_unused_result
  public func take(last count: Int) -> RawStream<Event> {
    return RawStream { observer in

      var values: [Event.Element] = []
      values.reserveCapacity(count)

      return self.observe { event in

        if let element = event.element {
          if values.count + 1 > count {
            values.removeFirst(values.count - count + 1)
          }
          values.append(element)
        } else if event.isCompletion {
          values.forEach(observer.next)
          observer.completed()
        } else if event.isFailure {
          observer.observer(event)
        }
      }
    }
  }

  // TODO: fix
  /// Throttle stream to emit at most one event per given `seconds` interval.
  @warn_unused_result
  public func throttle(seconds: TimeValue) -> RawStream<Event> {
    return RawStream { observer in
      var lastEventTime: TimeValue = SystemTime.distantPast
      return self.observe { event in
        if event.isTermination {
          observer.observer(event)
        } else {
          let now = SystemTime.now
          if now - lastEventTime > seconds {
            lastEventTime = now
            observer.observer(event)
          }
        }
      }
    }
  }
}

public extension RawStreamType where Event.Element: Equatable {

  /// Emit first element and then all elements that are not equal to their predecessor(s).
  @warn_unused_result
  public func distinct() -> RawStream<Event> {
    return distinct(areDistinct: !=)
  }
}

public extension RawStreamType where Event.Element: OptionalType, Event.Element.Wrapped: Equatable {

  /// Emit first element and then all elements that are not equal to their predecessor(s).
  @warn_unused_result
  public func distinct() -> RawStream<Event> {
    return distinct { a, b in
      switch (a._unbox, b._unbox) {
      case (.none, .some):
        return true
      case (.some, .none):
        return true
      case (.some(let old), .some(let new)) where old != new:
        return true
      default:
        return false
      }
    }
  }
}

// MARK: Combination

extension RawStreamType {

  /// Emit a combination of latest elements from each stream. Starts when both streams emit at least one element,
  /// and emits next when either stream generates an event.
  @warn_unused_result
  public func combineLatest<R: _StreamType, U: EventType>(with other: R, combine: (Event.Element?, Event, R.Event.Element?, R.Event, Bool) -> U?) -> RawStream<U> {
    return RawStream<U> { observer in
      let lock = NSRecursiveLock(name: "combineLatestWith")

      var latestMyElement: Event.Element?
      var latestTheirElement: R.Event.Element?
      var latestMyEvent: Event?
      var latestTheirEvent: R.Event?

      let dispatchNextIfPossible = { (isMy: Bool) -> () in
        if let latestMyEvent = latestMyEvent, let latestTheirEvent = latestTheirEvent {
          if let event = combine(latestMyElement, latestMyEvent, latestTheirElement, latestTheirEvent, isMy) {
            observer.observer(event)
          }
        }
      }

      let selfDisposable = self.observe { event in
        lock.atomic {
          if let element = event.element { latestMyElement = element }
          latestMyEvent = event
          if !event.isTermination || (latestTheirEvent?.isTermination ?? false) {
            dispatchNextIfPossible(true)
          }
        }
      }

      let otherDisposable = other.observe { event in
        lock.atomic {
          if let element = event.element { latestTheirElement = element }
          latestTheirEvent = event
          if !event.isTermination || (latestMyEvent?.isTermination ?? false) {
            dispatchNextIfPossible(false)
          }
        }
      }

      return CompositeDisposable([selfDisposable, otherDisposable])
    }
  }

  /// Merge emissions from both source and `other` into one stream.
  @warn_unused_result
  public func merge<R: _StreamType where R.Event == Event>(with other: R) -> RawStream<Event> {
    return RawStream<Event> { observer in
      let lock = NSRecursiveLock(name: "mergeWith")
      var numberOfOperations = 2
      let compositeDisposable = CompositeDisposable()
      let onBoth: (Event) -> Void = { event in
        if event.isCompletion {
          lock.atomic {
            numberOfOperations -= 1
            if numberOfOperations == 0 {
              observer.completed()
            }
          }
          return
        } else if event.isFailure {
          compositeDisposable.dispose()
        }
        observer.observer(event)
      }
      compositeDisposable += self.observe(observer: onBoth)
      compositeDisposable += other.observe(observer: onBoth)
      return compositeDisposable
    }
  }

  /// Prepend given event to the stream emission.
  @warn_unused_result
  public func start(with event: Event) -> RawStream<Event> {
    return RawStream { observer in
      observer.observer(event)
      return self.observe { event in
        observer.observer(event)
      }
    }
  }


  /// Emit elements from source and `other` in combination. This differs from `combineLatestWith` in
  /// that combinations are produced from elements at same positions.
  @warn_unused_result
  public func zip<R: _StreamType, U: EventType>(with other: R, zip: (Event, R.Event) -> U) -> RawStream<U> {
    return RawStream<U> { observer in
      let lock = NSRecursiveLock(name: "zipWith")

      var selfBuffer = Array<Event>()
      var otherBuffer = Array<R.Event>()
      let disposable = CompositeDisposable()

      let dispatchIfPossible = {
        while !selfBuffer.isEmpty && !otherBuffer.isEmpty {
          let event = zip(selfBuffer[0], otherBuffer[0])
          observer.observer(event)
          selfBuffer.removeFirst()
          otherBuffer.removeFirst()
          if event.isTermination {
            disposable.dispose()
          }
        }
      }

      disposable += self.observe { event in
        lock.atomic {
          selfBuffer.append(event)
          dispatchIfPossible()
        }
      }

      disposable += other.observe { event in
        lock.atomic {
          otherBuffer.append(event)
          dispatchIfPossible()
        }
      }
      
      return disposable
    }
  }
}

// MARK: Error Handling

public extension RawStreamType where Event: Errorable {

  /// Restart the stream in case of failure at most `times` number of times.
  @warn_unused_result
  public func retry(times: Int) -> RawStream<Event> {
    return RawStream { observer in
      var times = times
      let serialDisposable = SerialDisposable(otherDisposable: nil)

      var attempt: (() -> Void)?

      attempt = {
        serialDisposable.otherDisposable?.dispose()
        serialDisposable.otherDisposable = self.observe { event in
          if event.error != nil && times > 0 {
            times -= 1
            attempt?()
          } else {
            observer.observer(event)
            attempt = nil
          }
        }
      }

      attempt?()
      return BlockDisposable {
        serialDisposable.dispose()
        attempt = nil
      }
    }
  }
}

//  MARK: Utilities

public extension RawStreamType {

  /// Set the execution context in which to execute the stream (i.e. in which to run
  /// stream's producer).
  @warn_unused_result
  public func executeIn(_ context: ExecutionContext) -> RawStream<Event> {
    return RawStream { observer in
      let serialDisposable = SerialDisposable(otherDisposable: nil)
      context {
        if !serialDisposable.isDisposed {
          serialDisposable.otherDisposable = self.observe(observer: observer.observer)
        }
      }
      return serialDisposable
    }
  }

  /// Delay stream events for `interval` time.
  @warn_unused_result
  public func delay(interval: TimeValue, on queue: DispatchQueue) -> RawStream<Event> {
    return RawStream { observer in
      return self.observe { event in
        queue.after(when: interval) {
          observer.observer(event)
        }
      }
    }
  }

  // WONTDO: do

  /// Set the execution context in which to dispatch events (i.e. in which to run
  /// observers).
  @warn_unused_result
  public func observeIn(_ context: ExecutionContext) -> RawStream<Event> {
    return RawStream { observer in
      return self.observe { event in
        context {
          observer.observer(event)
        }
      }
    }
  }

  /// Supress events while last event generated on other stream is `false`.
  @warn_unused_result
  public func pausable<R: _StreamType where R.Event.Element == Bool>(by: R) -> RawStream<Event> {
    return RawStream { observer in

      var allowed: Bool = true

      let compositeDisposable = CompositeDisposable()
      compositeDisposable += by.observe { value in
        if let element = value.element {
          allowed = element
        } else {
          // ignore?
        }
      }

      compositeDisposable += self.observe { event in
        if event.isTermination {
          observer.observer(event)
        } else if allowed {
          observer.observer(event)
        }
      }

      return compositeDisposable
    }
  }

  // WONTDO: timeout
}

// MARK: Conditional, Boolean and Aggregational

public extension RawStreamType {

  // WONTDO: all

  /// Propagate event only from a stream that starts emitting first.
  @warn_unused_result
  public func amb<R: RawStreamType where R.Event == Event>(with other: R) -> RawStream<Event> {
    return RawStream { observer in
      let lock = NSRecursiveLock(name: "ambWith")
      var isOtherDispatching = false
      var isSelfDispatching = false
      let d1 = SerialDisposable(otherDisposable: nil)
      let d2 = SerialDisposable(otherDisposable: nil)

      d1.otherDisposable = self.observe { event in
        lock.atomic {
          guard !isOtherDispatching else { return }
          isSelfDispatching = true
          observer.observer(event)
          if !d2.isDisposed {
            d2.dispose()
          }
        }
      }

      d2.otherDisposable = other.observe { event in
        lock.atomic {
          guard !isSelfDispatching else { return }
          isOtherDispatching = true
          observer.observer(event)
          if !d1.isDisposed {
            d1.dispose()
          }
        }
      }

      return CompositeDisposable([d1, d2])
    }
  }

  /// First emit events from source and then from `other` stream.
  @warn_unused_result
  public func concat(with other: RawStream<Event>) -> RawStream<Event> {
    return RawStream { observer in
      let serialDisposable = SerialDisposable(otherDisposable: nil)
      serialDisposable.otherDisposable = self.observe { event in
        if event.isCompletion {
          serialDisposable.otherDisposable = other.observe(observer: observer.observer)
        } else {
          observer.observer(event)
        }
      }
      return serialDisposable
    }
  }

  // WONTDO: contains

  /// Emit default element is stream completes without emitting any element.
  @warn_unused_result
  public func defaultIfEmpty(_ element: Event.Element) -> RawStream<Event> {
    return RawStream { observer in
      var didEmitNonTerminal = false
      return self.observe { event in
        if event.isTermination {
          if !didEmitNonTerminal {
            observer.next(element)
            observer.completed()
          } else {
            observer.observer(event)
          }
        } else {
          didEmitNonTerminal = true
          observer.observer(event)
        }
      }
    }
  }

  /// Reduce stream events to a single event by applying given function on each emission.
  @warn_unused_result
  public func reduce<U: EventType>(_ initial: U, _ combine: (U, Event) -> U) -> RawStream<U> {
    return scan(initial, combine).take(last: 1)
  }
}

// MARK: Streams that emit other streams

public extension RawStreamType where Event.Element: _StreamType {

  public typealias InnerEvent = Event.Element.Event

  /// Flatten the stream by observing all inner streams and propagate events from each one as they come.
  @warn_unused_result
  public func merge<U: EventType>(unboxEvent: (InnerEvent) -> U, propagateErrorEvent: (Event, Observer<U>) -> Void) -> RawStream<U> {
    return RawStream<U> { observer in
      let lock = NSRecursiveLock(name: "merge")

      var numberOfOperations = 1
      let compositeDisposable = CompositeDisposable()

      let decrementNumberOfOperations = { () -> () in
        lock.atomic {
          numberOfOperations -= 1
          if numberOfOperations == 0 {
            observer.completed()
          }
        }
      }

      compositeDisposable += self.observe { outerEvent in

        if let stream = outerEvent.element {
          lock.atomic {
            numberOfOperations += 1
          }
          compositeDisposable += stream.observe { innerEvent in
            if !innerEvent.isCompletion {
              observer.observer(unboxEvent(innerEvent))
            } else {
              decrementNumberOfOperations()
            }
          }
        } else if outerEvent.isCompletion {
          decrementNumberOfOperations()
        } else if outerEvent.isFailure {
          propagateErrorEvent(outerEvent, observer)
        }
      }
      return compositeDisposable
    }
  }

  /// Flatten the stream by observing and propagating emissions only from latest stream.
  @warn_unused_result
  public func switchToLatest<U: EventType>(unboxEvent: (InnerEvent) -> U, propagateErrorEvent: (Event, Observer<U>) -> Void) -> RawStream<U> {
    return RawStream<U> { observer in
      let serialDisposable = SerialDisposable(otherDisposable: nil)
      let compositeDisposable = CompositeDisposable([serialDisposable])

      var outerCompleted: Bool = false
      var innerCompleted: Bool = false

      compositeDisposable += self.observe { outerEvent in
        if outerEvent.isFailure {
          propagateErrorEvent(outerEvent, observer)
        } else if outerEvent.isCompletion {
          outerCompleted = true
          if innerCompleted {
            observer.completed()
          }
        } else if let stream = outerEvent.element {
          innerCompleted = false
          serialDisposable.otherDisposable?.dispose()
          serialDisposable.otherDisposable = stream.observe { innerEvent in

            if !innerEvent.isCompletion {
              observer.observer(unboxEvent(innerEvent))
            } else {
              innerCompleted = true
              if outerCompleted {
                observer.completed()
              }
            }
          }
        }
      }

      return compositeDisposable
    }
  }

  /// Flatten the stream by sequentially observing inner streams in order in which they
  /// arrive, starting next observation only after previous one completes.
  @warn_unused_result
  public func concat<U: EventType>(unboxEvent: (InnerEvent) -> U, propagateErrorEvent: (Event, Observer<U>) -> Void) -> RawStream<U> {
    return RawStream<U> { observer in
      typealias Task = Event.Element
      let lock = NSRecursiveLock(name: "concat")

      let serialDisposable = SerialDisposable(otherDisposable: nil)
      let compositeDisposable = CompositeDisposable([serialDisposable])

      var outerCompleted: Bool = false
      var innerCompleted: Bool = true

      var taskQueue: [Task] = []

      var startNextOperation: (() -> ())! = nil
      startNextOperation = {
        innerCompleted = false

        let task = lock.atomic { taskQueue.removeFirst() }

        serialDisposable.otherDisposable?.dispose()
        serialDisposable.otherDisposable = task.observe { event in

          if !event.isCompletion {
            observer.observer(unboxEvent(event))
          } else {
            innerCompleted = true
            if !taskQueue.isEmpty {
              startNextOperation()
            } else if outerCompleted {
              observer.completed()
            }
          }
        }
      }

      let addToQueue = { (task: Task) -> () in
        lock.atomic {
          taskQueue.append(task)
        }
        if innerCompleted {
          startNextOperation()
        }
      }

      compositeDisposable += self.observe { myEvent in
        if let stream = myEvent.element {
          addToQueue(stream)
        } else if myEvent.isFailure {
          propagateErrorEvent(myEvent, observer)
        } else if myEvent.isCompletion {
          outerCompleted = true
          if innerCompleted {
            observer.completed()
          }
        }
      }

      return compositeDisposable
    }
  }
}

// MARK: Connectable

extension RawStreamType {

  /// Ensure that all observers see the same sequence of elements. Connectable.
  @warn_unused_result
  public func replay(_ limit: Int = Int.max) -> RawConnectableStream<Self> {
    if limit == 1 {
      return RawConnectableStream(source: self, subject: AnySubject(base: ReplayOneSubject()))
    } else {
      return RawConnectableStream(source: self, subject: AnySubject(base: ReplaySubject(bufferSize: limit)))
    }
  }

  /// Convert stream to a connectable stream.
  @warn_unused_result
  public func publish() -> RawConnectableStream<Self> {
    return RawConnectableStream(source: self, subject: AnySubject(base: PublishSubject()))
  }
}

// MARK: - ConnectableStreamType

/// Represents a stream that is started by calling `connect` on it.
public protocol ConnectableStreamType: _StreamType {

  /// Start the stream.
  func connect() -> Disposable
}

// MARK: - RawConnectableStream

/// Makes a stream connectable through the given subject.
public final class RawConnectableStream<R: RawStreamType>: ConnectableStreamType {

  private let lock = SpinLock()
  private let source: R
  private let subject: AnySubject<R.Event>
  private var connectionDisposable: Disposable? = nil

  public init(source: R, subject: AnySubject<R.Event>) {
    self.source = source
    self.subject = subject
  }

  /// Start the stream.
  public func connect() -> Disposable {
    return lock.atomic {
      if let connectionDisposable = connectionDisposable {
        return connectionDisposable
      } else {
        return source.observe(observer: subject.on)
      }
    }
  }

  /// Register an observer that will receive events from the stream.
  /// Note that the events will not be generated until `connect` is called.
  @warn_unused_result
  public func observe(observer: (R.Event) -> Void) -> Disposable {
    return subject.observe(observer: observer)
  }
}

public extension ConnectableStreamType {

  /// Convert connectable stream into the ordinary stream by calling `connect`
  /// on first subscription and calling dispose when number of observers goes down to zero.
  @warn_unused_result
  public func refCount() -> RawStream<Event> {
    var count = 0
    var connectionDisposable: Disposable? = nil
    return RawStream { observer in
      count = count + 1
      let disposable = self.observe(observer: observer.observer)
      if connectionDisposable == nil {
        connectionDisposable = self.connect()
      }
      return BlockDisposable {
        disposable.dispose()
        count = count - 1
        if count == 0 {
          connectionDisposable?.dispose()
        }
      }
    }
  }
}

// MARK: Helpers

public protocol OptionalType {
  associatedtype Wrapped
  var _unbox: Optional<Wrapped> { get }
  init(nilLiteral: ())
  init(_ some: Wrapped)
}

extension Optional: OptionalType {
  public var _unbox: Optional<Wrapped> {
    return self
  }
}
