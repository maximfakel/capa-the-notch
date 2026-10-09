import Foundation

/// MultitouchSupport, opened at run time so a framework that is missing or
/// changed fails softly with a sentence instead of a crash at launch.
///
/// The layout of one contact is the one every open-source reader of this
/// framework uses (MiddleClick, OpenMultitouchSupport): 96 bytes, read here by
/// offset rather than through a Swift struct whose layout is not promised.
final class Multitouch {
    typealias Device = UnsafeMutableRawPointer
    typealias FrameCallback = @convention(c) (Device?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void

    private typealias CreateList = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias Register = @convention(c) (Device, FrameCallback) -> Void
    private typealias Start = @convention(c) (Device, Int32) -> Int32
    private typealias Stop = @convention(c) (Device) -> Int32
    private typealias IsBuiltIn = @convention(c) (Device) -> Bool
    private typealias Dimensions = @convention(c) (Device, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    private typealias FamilyID = @convention(c) (Device, UnsafeMutablePointer<Int32>) -> Int32

    static let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    static let contactStride = 96

    struct DeviceInfo {
        let device: Device
        let builtIn: Bool
        let familyID: Int32
        /// Sensor surface, in hundredths of a millimetre.
        let width: Int32
        let height: Int32
        var startStatus: Int32 = .min
    }

    private let createList: CreateList
    private let register: Register
    private let unregister: Register
    private let start: Start
    private let stop: Stop
    private let isBuiltIn: IsBuiltIn?
    private let dimensions: Dimensions?
    private let familyID: FamilyID?
    private var list: CFMutableArray?
    private(set) var devices: [DeviceInfo] = []

    /// Nil, with the reason, when the framework or a symbol it needs is gone.
    static func open() -> Result<Multitouch, SpikeError> {
        guard let handle = dlopen(path, RTLD_NOW) else {
            return .failure(SpikeError("dlopen failed: \(String(cString: dlerror()))"))
        }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let createList = symbol("MTDeviceCreateList", CreateList.self),
              let register = symbol("MTRegisterContactFrameCallback", Register.self),
              let unregister = symbol("MTUnregisterContactFrameCallback", Register.self),
              let start = symbol("MTDeviceStart", Start.self),
              let stop = symbol("MTDeviceStop", Stop.self)
        else {
            return .failure(SpikeError("a required symbol is missing"))
        }
        return .success(Multitouch(
            createList: createList, register: register, unregister: unregister, start: start, stop: stop,
            isBuiltIn: symbol("MTDeviceIsBuiltIn", IsBuiltIn.self),
            dimensions: symbol("MTDeviceGetSensorSurfaceDimensions", Dimensions.self),
            familyID: symbol("MTDeviceGetFamilyID", FamilyID.self)
        ))
    }

    private init(createList: CreateList, register: Register, unregister: Register, start: Start, stop: Stop,
                 isBuiltIn: IsBuiltIn?, dimensions: Dimensions?, familyID: FamilyID?) {
        self.createList = createList
        self.register = register
        self.unregister = unregister
        self.start = start
        self.stop = stop
        self.isBuiltIn = isBuiltIn
        self.dimensions = dimensions
        self.familyID = familyID
    }

    func startAll(_ callback: FrameCallback) {
        guard let list = createList()?.takeRetainedValue() else { return }
        self.list = list
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            var width: Int32 = 0, height: Int32 = 0, family: Int32 = 0
            _ = dimensions?(device, &width, &height)
            _ = familyID?(device, &family)
            var info = DeviceInfo(device: device, builtIn: isBuiltIn?(device) ?? false, familyID: family, width: width, height: height)
            register(device, callback)
            info.startStatus = start(device, 0)
            devices.append(info)
        }
    }

    func stopAll(_ callback: FrameCallback) {
        for info in devices {
            unregister(info.device, callback)
            _ = stop(info.device)
        }
        devices = []
        list = nil
    }
}

/// One contact in a frame, read by offset.
struct Contact {
    let identifier: Int32
    let state: Int32
    let x: Float, y: Float // 0...1 across the surface, origin bottom-left
    let total: Float
    let pressure: Float
    let majorAxis: Float
    let minorAxis: Float
    let density: Float
    let frame: Int32

    init(_ base: UnsafeMutableRawPointer, index: Int) {
        let p = base + index * Multitouch.contactStride
        frame = p.load(fromByteOffset: 0, as: Int32.self)
        identifier = p.load(fromByteOffset: 16, as: Int32.self)
        state = p.load(fromByteOffset: 20, as: Int32.self)
        x = p.load(fromByteOffset: 32, as: Float.self)
        y = p.load(fromByteOffset: 36, as: Float.self)
        total = p.load(fromByteOffset: 48, as: Float.self)
        pressure = p.load(fromByteOffset: 52, as: Float.self)
        majorAxis = p.load(fromByteOffset: 60, as: Float.self)
        minorAxis = p.load(fromByteOffset: 64, as: Float.self)
        density = p.load(fromByteOffset: 92, as: Float.self)
    }

    /// Making touch (3) or touching (4): a finger on the glass, not hovering
    /// over it or lifting off it.
    var isDown: Bool { state == 3 || state == 4 }
    var looksSane: Bool { (0...7).contains(state) && (-0.2...1.2).contains(x) && (-0.2...1.2).contains(y) }
}

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
