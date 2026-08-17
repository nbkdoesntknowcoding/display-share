//
//  CGVirtualDisplayPrivate.h
//  Display Share — Phase 0 feasibility spike
//
//  Re-declaration of Apple's PRIVATE CoreGraphics virtual-display class cluster.
//
//  PROVENANCE / LICENSING
//  ----------------------
//  These declarations were derived by ObjC runtime introspection of
//  CoreGraphics on the target machine (macOS 26.2, build 25C56, Apple M4) —
//  see docs/phase0-findings.md for the raw dump. They are a description of an
//  ABI that exists on the running system, not a copy of any third-party source
//  file. No code was copied from GPL-licensed projects (opendisplay, Lumen,
//  Sunshine, moonlight-qt). Every type below matches the introspected type
//  encoding exactly:  'I' -> unsigned int (32-bit), 'd' -> double,
//  'B' -> BOOL, '@?' -> block.
//
//  CAVEAT
//  ------
//  This is a private API. It is absent from the public SDK headers, cannot be
//  shipped on the Mac App Store, and may change or disappear in any macOS
//  release. Every call site must degrade gracefully. See the risk table in the
//  research doc.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - CGVirtualDisplayMode

/// One advertised display mode. Note the API caps refreshRate at 60 Hz in
/// practice; higher values are accepted but not honoured.
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@property(readonly, nonatomic) unsigned int width;
@property(readonly, nonatomic) unsigned int height;
@property(readonly, nonatomic) double refreshRate;
@end

#pragma mark - CGVirtualDisplaySettings

/// Mutable settings applied to a live display via -[CGVirtualDisplay applySettings:].
/// Applying new settings is how resolution changes are performed without
/// destroying the display (and therefore without destroying the user's window
/// arrangement).
@interface CGVirtualDisplaySettings : NSObject
- (instancetype)init;
@property(nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
/// 1 enables Retina/HiDPI backing scale. 0 is 1x.
@property(nonatomic, assign) unsigned int hiDPI;
@property(nonatomic, assign) unsigned int rotation;
@property(nonatomic, assign) double refreshDeadline;
@property(nonatomic, assign) BOOL isReference;
@end

#pragma mark - CGVirtualDisplayDescriptor

/// Immutable-at-creation identity of the display: EDID-ish metadata plus the
/// queue/handler used to tell us the display went away.
@interface CGVirtualDisplayDescriptor : NSObject
- (instancetype)init;

@property(nonatomic, strong) NSString *name;
@property(nonatomic, assign) CGSize sizeInMillimeters;
@property(nonatomic, assign) unsigned int maxPixelsWide;
@property(nonatomic, assign) unsigned int maxPixelsHigh;

@property(nonatomic, assign) unsigned int vendorID;
@property(nonatomic, assign) unsigned int productID;
@property(nonatomic, assign) unsigned int serialNum;
@property(nonatomic, assign) unsigned int serialNumber;

@property(nonatomic, assign) CGPoint redPrimary;
@property(nonatomic, assign) CGPoint greenPrimary;
@property(nonatomic, assign) CGPoint bluePrimary;
@property(nonatomic, assign) CGPoint whitePoint;

/// Queue the terminationHandler is delivered on. Must be set before the
/// display is created or CoreGraphics will reject it.
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy, nullable) void (^terminationHandler)(id _Nullable, id _Nullable);

@property(readonly, nonatomic) NSDictionary *displayInfo;

/// Newer alias for -setQueue:. Present on macOS 14+; both selectors exist on 26.2.
- (void)setDispatchQueue:(dispatch_queue_t)queue;
- (void)setDisplayInfoValue:(id)value forKey:(NSString *)key;
@end

#pragma mark - CGVirtualDisplay

/// The live display. CRITICAL LIFECYCLE NOTE: the display exists only as long
/// as this object is retained by a running process. Releasing it — or the
/// owning process exiting or crashing — destroys the display immediately and
/// macOS reflows every window that was on it. This is precisely why the
/// product holds it in a dedicated `vd_helper` subprocess (see Task 1.1).
@interface CGVirtualDisplay : NSObject
/// Nullable: CoreGraphics returns nil if it refuses to create the display
/// (bad descriptor, too many virtual displays, API withdrawn).
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
/// Returns NO if CoreGraphics rejected the mode list.
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;

@property(readonly, nonatomic) CGDirectDisplayID displayID;
@property(readonly, nonatomic) NSString *name;
@property(readonly, nonatomic) unsigned int vendorID;
@property(readonly, nonatomic) unsigned int productID;
@property(readonly, nonatomic) unsigned int serialNum;
@property(readonly, nonatomic) CGSize sizeInMillimeters;
@property(readonly, nonatomic) unsigned int maxPixelsWide;
@property(readonly, nonatomic) unsigned int maxPixelsHigh;
@property(readonly, nonatomic) unsigned int hiDPI;
@property(readonly, nonatomic) unsigned int rotation;
@property(readonly, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@end

NS_ASSUME_NONNULL_END
