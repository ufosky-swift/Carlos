import Foundation

/// This class is a disk cache level. It has a configurable total size that defaults to 100 MB.
public class DiskCacheLevel<K: StringConvertible, T: NSCoding>: CacheLevel {
  /// At the moment the disk cache level only accepts String keys
  public typealias KeyType = K
  public typealias OutputType = T
  
  private let path: String
  private var size: UInt64 = 0
  private let fileManager: NSFileManager
  
  /// The capacity of the cache
  public var capacity: UInt64 = 0 {
    didSet {
      dispatch_async(self.cacheQueue, {
        self.controlCapacity()
      })
    }
  }
  
  private lazy var cacheQueue : dispatch_queue_t = {
    return dispatch_queue_create(CarlosGlobals.QueueNamePrefix + self.path.lastPathComponent, DISPATCH_QUEUE_SERIAL)
  }()
  
  /**
  This method is a no-op since all the contents of the cache are stored on disk, so removing them would have no benefit for memory pressure
  */
  public func onMemoryWarning() {}
  
  /**
  Initializes a new disk cache level
  
  :param: path The path to the disk storage. Defaults to a Carlos specific folder in the Caches sandbox folder.
  :param: capacity The total capacity in bytes for the disk cache. Defaults to 100 MB
  :param: fileManager The file manager to use. Defaults to the default NSFileManager. It's here mainly for dependency injection testing purposes.
  */
  public init(path: String = CarlosGlobals.Caches.stringByAppendingPathComponent(CarlosGlobals.QueueNamePrefix + "default"), capacity: UInt64 = 100 * 1024 * 1024, fileManager: NSFileManager = NSFileManager.defaultManager()) {
    self.path = path
    self.fileManager = fileManager
    self.capacity = capacity
    
    fileManager.createDirectoryAtPath(path, withIntermediateDirectories: true, attributes: [:], error: nil)
    
    dispatch_async(self.cacheQueue, {
      self.calculateSize()
      self.controlCapacity()
    })
  }
  
  /**
  Asynchronously sets a value for the given key
  
  :param: value The value to save on disk
  :param: key The key for the value
  */
  public func set(value: T, forKey key: K) {
    dispatch_async(cacheQueue, {
      Logger.log("Setting a value for the key \(key.toString()) on the disk cache \(self)")
      self.setDataSync(value, key: key)
    })
  }
  
  /**
  Asynchronously gets the value for the given key
  
  :param: key The key for the value
  
  :returns: A CacheRequest where you can call onSuccess and onFailure to be notified of the result of the fetch
  */
  public func get(key: KeyType) -> CacheRequest<OutputType> {
    let request = CacheRequest<OutputType>()
    
    dispatch_async(cacheQueue, {
      let path = self.pathForKey(key)
      
      if let obj = NSKeyedUnarchiver.su_unarchiveObjectWithFilePath(path) as? T {
        Logger.log("Fetched \(key.toString()) on disk level")
        dispatch_async(dispatch_get_main_queue(), {
          request.succeed(obj)
        })
        self.updateDiskAccessDateAtPath(path)
      } else {
        // Remove the file (maybe corrupted)
        self.fileManager.removeItemAtPath(path, error: nil)
        
        Logger.log("Failed fetching \(key.toString()) on the disk cache")
        dispatch_async(dispatch_get_main_queue(), {
          request.fail(nil)
        })
      }
    })
    
    return request
  }
  
  /**
  Asynchronously clears the contents of the cache
  
  All the cached files will be removed from the disk storage
  */
  public func clear() {
    dispatch_async(cacheQueue, {
      for filePath in self.itemsInDirectory(self.path) {
        self.fileManager.removeItemAtPath(filePath, error: nil)
      }
      self.calculateSize()
    })
  }
  
  // MARK: Private
  
  private func removeData(key: K) {
    dispatch_async(cacheQueue, {
      self.removeFileAtPath(self.pathForKey(key))
    })
  }
  
  private func updateAccessDate(@autoclosure(escaping) getData: () -> T?, key: K) {
    dispatch_async(cacheQueue, {
      let path = self.pathForKey(key)
      if !self.updateDiskAccessDateAtPath(path) && !self.fileManager.fileExistsAtPath(path) {
        if let data = getData() {
          self.setDataSync(data, key: key)
        }
      }
    })
  }
  
  private func pathForKey(key: K) -> String {
    return path.stringByAppendingPathComponent(key.toString().MD5String())
  }
  
  private func sizeForFileAtPath(filePath: String) -> UInt64 {
    var size: UInt64 = 0
    
    if let attributes: NSDictionary = fileManager.attributesOfItemAtPath(filePath, error: nil) {
      size = attributes.fileSize()
    }
    
    return size
  }
  
  private func calculateSize() {
    size = itemsInDirectory(path).reduce(0, combine: { (accumulator, filePath) in
      accumulator + sizeForFileAtPath(filePath)
    })
  }
  
  private func controlCapacity() {
    if size > capacity {
      enumerateContentsOfDirectorySortedByAscendingModificationDateAtPath(path) { (URL, inout stop: Bool) in
        if let path = URL.path {
          removeFileAtPath(path)
          stop = size <= capacity
        }
      }
    }
  }
  
  private func setDataSync(data: T, key: K) {
    let path = pathForKey(key)
    let previousSize = sizeForFileAtPath(path)
    if !NSKeyedArchiver.archiveRootObject(data, toFile: path) {
      Logger.log("Failed to write key \(key.toString()) on the disk cache", .Error)
    }
    
    size += max(0, sizeForFileAtPath(path) - previousSize)
    
    controlCapacity()
  }
  
  private func updateDiskAccessDateAtPath(path: String) -> Bool {
    return fileManager.setAttributes([
      NSFileModificationDate: NSDate()
    ], ofItemAtPath: path, error: nil)
  }
  
  private func removeFileAtPath(path: String) {
    if let attributes: NSDictionary = fileManager.attributesOfItemAtPath(path, error: nil)
       where fileManager.removeItemAtPath(path, error: nil) {
      size -= attributes.fileSize()
    }
  }
  
  private func itemsInDirectory(directory: String) -> [String] {
    var items: [String] = []
    
    if let contents = fileManager.contentsOfDirectoryAtPath(directory, error: nil) as? [String] {
      items = contents.map {
        directory.stringByAppendingPathComponent($0)
      }
    }
    
    return items
  }
  
  private func enumerateContentsOfDirectorySortedByAscendingModificationDateAtPath(path: String, @noescape usingBlock block: (NSURL, inout Bool) -> Void) {
    let property = NSURLContentModificationDateKey
    if let directoryURL = NSURL(fileURLWithPath: path),
      let contents = fileManager.contentsOfDirectoryAtURL(directoryURL, includingPropertiesForKeys: [property], options: .allZeros, error: nil) as? [NSURL] {
        let sortedContents = contents.sorted({ (URL1, URL2) in
          var value1: AnyObject?
          if !URL1.getResourceValue(&value1, forKey: property, error: nil) {
            return true
          }
          
          var value2: AnyObject?
          if !URL2.getResourceValue(&value2, forKey: property, error: nil) {
            return false
          }
          
          if let date1 = value1 as? NSDate, let date2 = value2 as? NSDate {
            return date1.compare(date2) == .OrderedAscending
          }
          
          return false
        })
        
        for value in sortedContents {
          var stop = false
          block(value, &stop)
          if stop {
            break
          }
        }
    }
  }
}