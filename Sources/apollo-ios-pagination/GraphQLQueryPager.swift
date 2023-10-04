import Apollo
import ApolloAPI
import Foundation

/// Handles pagination in the queue by managing multiple query watchers.
public class GraphQLQueryPager<InitialQuery: GraphQLQuery, PaginatedQuery: GraphQLQuery> {
  
  /// The result of either the initial query or the paginated query, for the purpose of extracting a `PageInfo` from it.
  public enum PageExtractionData {
    case initial(InitialQuery.Data)
    case paginated(PaginatedQuery.Data)
  }
  
  /// Whether or not we can load more information based on the current page.
  public var canLoadNext: Bool { currentPageInfo?.wrappedValue.canLoadMore ?? false }
  
  public typealias Output = (InitialQuery.Data, [PaginatedQuery.Data], UpdateSource)
  
  private let client: any ApolloClientProtocol
  private var firstPageWatcher: GraphQLQueryWatcher<InitialQuery>?
  private var nextPageWatchers: [GraphQLQueryWatcher<PaginatedQuery>] = []
  private let initialQuery: InitialQuery
  private let nextPageResolver: (PaginationInfo) -> PaginatedQuery?
  private let extractPageInfo: (PageExtractionData) -> PaginationInfo
  private var currentPageInfo: Hashed<PaginationInfo>? { pageOrder.last }
  
  private var onUpdate: ((Output) -> Void)?
  private var onError: ((Error) -> Void)?
  
  private var initialPageResult: InitialQuery.Data?
  private var latest: (InitialQuery.Data, [PaginatedQuery.Data])? {
    guard let initialPageResult else { return nil }
    return (initialPageResult, pageOrder.compactMap({ pageMap[$0] }))
  }
  
  /// Array of page info used to fetch next pages. Maintains an order of values used to fetch each page in a connection.
  private var pageOrder = [Hashed<PaginationInfo>]()
  
  /// Maps each page info to latest results from internal watchers.
  private var pageMap = [Hashed<PaginationInfo>: PaginatedQuery.Data]()
  
  /// Designated Initializer
  /// - Parameters:
  ///   - client: Apollo Client
  ///   - initialQuery: The initial query that is being watched
  ///   - extractPageInfo: The `PageInfo` derived from `PageExtractionData`
  ///   - nextPageResolver: The resolver that can derive the query for loading more. This can be a different query than the `initialQuery`.
  ///   - onError: The callback when there is an error.
  public init<P: PaginationInfo>(
    client: ApolloClientProtocol,
    initialQuery: InitialQuery,
    extractPageInfo: @escaping (PageExtractionData) -> P,
    nextPageResolver: @escaping (P) -> PaginatedQuery
  ) {
    self.client = client
    self.initialQuery = initialQuery
    self.extractPageInfo = extractPageInfo
    self.nextPageResolver = { page in
      guard let page = page as? P else { return nil }
      return nextPageResolver(page)
    }
  }
  
  // MARK: - Public API
  
  /// Subscribe to new data from this watcher.
  /// - Returns: An async stream that can be iterated over.
  public func subscribe() -> AsyncStream<Result<Output, Error>> {
    AsyncStream { continuation in
      self.onUpdate = { continuation.yield(.success($0)) }
      self.onError = { continuation.yield(.failure($0)) }
      continuation.onTermination = { @Sendable [weak self] _ in
        self?.cancel()
      }
    }
  }
  
  /// Loads the first page of results.
  /// This method is non-destructive: It will re-fetch the contents of the first page, without modifying any of the other pages, should there be any.
  public func fetch(cachePolicy: CachePolicy = .returnCacheDataAndFetch) {
    defer { firstPageWatcher?.refetch(cachePolicy: cachePolicy) }
    guard firstPageWatcher == nil else { return }
    self.firstPageWatcher = GraphQLQueryWatcher(
      client: client,
      query: initialQuery,
      resultHandler: { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let data):
          if case .server = data.source, let firstPageData = data.data {
            let page = Hashed(wrappedValue: self.extractPageInfo(.initial(firstPageData)))
            pageOrder.append(page)
          }
          self.initialPageResult = data.data
          if let latest = self.latest {
            let (firstPage, nextPage) = latest
            self.onUpdate?((firstPage, nextPage, data.source == .cache ? .cache : .fetch))
          }
        case .failure(let error):
          self.onError?(error)
        }
      }
    )
  }
  
  /// Loads the next page, based on the latest page info.
  public func loadMore(
    cachePolicy: CachePolicy = .fetchIgnoringCacheData,
    completion: (() -> Void)? = nil
  ) -> Bool {
    guard let currentPageInfo else {
      assertionFailure("No page info detected -- are you calling `loadMore` prior to calling the initial fetch?")
      return false
    }
    guard let nextPageQuery = nextPageResolver(currentPageInfo.wrappedValue),
          currentPageInfo.wrappedValue.canLoadMore
    else { return false }
    let watcher = GraphQLQueryWatcher(client: client, query: nextPageQuery) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let data):
        guard let nextPageData = data.data else { return }
        
        let page = Hashed(wrappedValue: self.extractPageInfo(.paginated(nextPageData)))
        if case .server = data.source {
          pageOrder.append(page)
        }
        self.pageMap[page] = data.data
        
        if let latest = self.latest {
          let (firstPage, nextPage) = latest
          self.onUpdate?((firstPage, nextPage, data.source == .cache ? .cache : .fetch))
        }
      case .failure(let error):
        self.onError?(error)
      }
      completion?()
    }
    nextPageWatchers.append(watcher)
    watcher.refetch(cachePolicy: cachePolicy)
    return true
  }
  
  /// Reloads all data, starting at the first query, resetting pagination state.
  public func refetch() {
    cancel()
    fetch()
  }
  
  /// Cancel any in progress fetching operations and unsubscribe from the store.
  public func cancel() {
    nextPageWatchers.forEach { $0.cancel() }
    nextPageWatchers = []
    firstPageWatcher?.cancel()
    firstPageWatcher = nil
    
    pageMap = [:]
    pageOrder = []
    initialPageResult = nil
  }
  
  deinit {
    firstPageWatcher?.cancel()
    nextPageWatchers.forEach { $0.cancel() }
  }
}

extension GraphQLQueryPager {
  /// Convenience initializer: Returns a `GraphQLQueryPager` that is built around paginating forwards.
  public static func makeForwardQueryPager(
    client: ApolloClientProtocol,
    initialQuery: InitialQuery,
    extractPageInfo: @escaping (PageExtractionData) -> ForwardPagination,
    nextPageResolver: @escaping (ForwardPagination) -> PaginatedQuery
  ) -> GraphQLQueryPager {
    .init(
      client: client,
      initialQuery: initialQuery,
      extractPageInfo: extractPageInfo,
      nextPageResolver: nextPageResolver
    )
  }
}

extension GraphQLQueryPager {
  /// Convenience initializer: Returns a `GraphQLQueryPager` that is built around paginating backwards.
  public static func makeReverseQueryPager(
    client: ApolloClientProtocol,
    initialQuery: InitialQuery,
    extractPageInfo: @escaping (PageExtractionData) -> ReversePagination,
    nextPageResolver: @escaping (ReversePagination) -> PaginatedQuery
  ) -> GraphQLQueryPager {
    .init(
      client: client,
      initialQuery: initialQuery,
      extractPageInfo: extractPageInfo,
      nextPageResolver: nextPageResolver
    )
  }
}

@propertyWrapper
private struct Hashed<Wrapped>: Hashable {
  var wrappedValue: Wrapped
  
  public var id: AnyHashable {
    if let wrappedValue = wrappedValue as? (any Hashable) {
      return AnyHashable(wrappedValue)
    } else {
      assertionFailure("Your concrete `PaginationInfo` type must be Hashable in order to ensure stable behavior!")
      return _id
    }
  }
  
  private let _id: UUID = UUID()
  
  init(wrappedValue: Wrapped) {
    self.wrappedValue = wrappedValue
  }
  
  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
  
  static func == (lhs: Hashed<Wrapped>, rhs: Hashed<Wrapped>) -> Bool {
    lhs.id == rhs.id
  }
}
