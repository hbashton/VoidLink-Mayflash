//
//  ControllerSupport.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//
//  Modified by True砖家 since 2024.6.16
//  Copyright © 2024 True砖家 @ Bilibili. All rights reserved.
//

#import "ControllerSupport.h"
#import "OnScreenControls.h"
#import "VoidController.h"
#import "VoidLink-Swift.h"

#import "DataManager.h"
#import "Logger.h"
#include "Limelight.h"
#include <stdatomic.h>
#include <math.h>

@import GameController;
#if !TARGET_OS_TV
    @import CoreMotion;
#endif
@import AudioToolbox;

static const double MOUSE_SPEED_DIVISOR = 1.25;
static __weak ControllerSupport *VLSharedControllerSupport = nil;

static CGFloat normalizedTriggerInput(CGFloat value) {
    if (!isfinite(value)) return 0;
    CGFloat clampedValue = fmin(fmax(value, 0), 1);
    CGFloat deadzone = ControllerUtil.controllerTriggerDeadzone;
    if (clampedValue <= deadzone) return 0;
    return (clampedValue - deadzone) / (1.0 - deadzone);
}

static unsigned char triggerValueToByte(CGFloat value) {
    return (unsigned char)lrint(normalizedTriggerInput(value) * 255.0);
}

static NSString *diagnosticLogicalControlName(NSInteger elementFlag) {
    if (elementFlag == ControllerElementStart) return @"start";
    if (elementFlag == ControllerElementLeftTrigger) return @"left_trigger";
    if (elementFlag == ControllerElementRightTrigger) return @"right_trigger";
    return [NSString stringWithFormat:@"0x%lx", (unsigned long)elementFlag];
}

static NSArray<NSDictionary<NSString *, id> *> *diagnosticMappedControls(
    NSDictionary<NSNumber *, GCControllerElement *> *elementMap,
    GCPhysicalInputProfile *profile
) {
    NSMutableArray<NSDictionary<NSString *, id> *> *mappedControls = [NSMutableArray array];
    NSDictionary<NSString *, GCControllerElement *> *physicalElements = profile.elements ?: @{};
    [elementMap enumerateKeysAndObjectsUsingBlock:^(NSNumber *elementFlag, GCControllerElement *element, BOOL *stop) {
        NSMutableArray<NSString *> *physicalNames = [NSMutableArray array];
        [physicalElements enumerateKeysAndObjectsUsingBlock:^(NSString *name, GCControllerElement *physicalElement, BOOL *innerStop) {
            if (physicalElement == element) [physicalNames addObject:name];
        }];
        [mappedControls addObject:@{
            @"logical_flag": elementFlag,
            @"logical_control": diagnosticLogicalControlName(elementFlag.integerValue),
            @"physical_elements": physicalNames
        }];
    }];
    return mappedControls;
}

static NSString *diagnosticPhysicalNameForElement(
    GCPhysicalInputProfile *profile,
    GCControllerElement *element
) {
    if (element == nil) return @"";
    __block NSString *matchedName = @"";
    [profile.elements enumerateKeysAndObjectsUsingBlock:^(NSString *name, GCControllerElement *candidate, BOOL *stop) {
        if (candidate == element) {
            matchedName = name;
            *stop = YES;
        }
    }];
    return matchedName;
}

static NSDictionary<NSString *, id> *diagnosticCommonControllerFields(VoidController *controller) {
    GCController *gamepad = controller.gamepad;
    return @{
        @"device_id": controller.diagnosticID ?: @"unknown",
        @"local_endpoint": @(controller.playerIndex),
        @"sunshine_port": controller.streamPlayerIndex >= 0 ? @(controller.streamPlayerIndex + 1) : @0,
        @"profile": gamepad.extendedGamepad != nil ? @"extended" : @"generic",
        @"vendor": gamepad.vendorName ?: @"unknown",
        @"product_category": gamepad.productCategory ?: @"unknown"
    };
}

static void recordStreamingRadialButtonSource(
    VoidController *controller,
    int buttonFlag,
    BOOL pressed,
    NSString *physicalElementName
) {
    NSMutableDictionary<NSString *, id> *fields =
        [NSMutableDictionary dictionaryWithDictionary:diagnosticCommonControllerFields(controller)];
    fields[@"source_control"] = diagnosticLogicalControlName(buttonFlag);
    fields[@"source_control_raw"] = @(buttonFlag);
    fields[@"mapped_physical_element"] = physicalElementName ?: @"";
    fields[@"configured_streaming_menu_control"] = @"start";
    fields[@"pressed"] = @(pressed);
    [ControllerDiagnostics recordEvent:@"controller_support_streaming_radial_button" fields:fields];
}

static void recordControllerDiscovery(GCController *controller, NSString *source) {
    GCPhysicalInputProfile *profile = controller.physicalInputProfile;
    NSDictionary<NSString *, id> *fields = @{
        @"source": source ?: @"unknown",
        @"vendor": controller.vendorName ?: @"unknown",
        @"product_category": controller.productCategory ?: @"unknown",
        @"profile": controller.extendedGamepad != nil ? @"extended" : @"generic",
        @"physical_elements": profile.elements.allKeys ?: @[]
    };
    [ControllerDiagnostics recordEvent:@"controller_discovered" fields:fields];
}

static void recordControllerInputCallback(
    VoidController *controller,
    NSString *source,
    GCPhysicalInputProfile *profile,
    GCControllerElement *changedElement,
    NSString *changedElementName,
    NSDictionary<NSNumber *, NSNumber *> *buttonStates,
    NSDictionary<NSNumber *, GCControllerElement *> *elementMap,
    BOOL meaningfulInput,
    CGFloat leftX,
    CGFloat leftY,
    CGFloat rightX,
    CGFloat rightY,
    CGFloat leftTrigger,
    CGFloat rightTrigger
) {
    CFTimeInterval now = CACurrentMediaTime();
    NSUInteger callbackCount;
    NSString *resolvedChangedElementName = changedElementName.length > 0
        ? changedElementName
        : ([source isEqualToString:@"generic"]
            ? diagnosticPhysicalNameForElement(profile, changedElement)
            : @"");
    NSMutableArray<NSDictionary<NSString *, id> *> *physicalButtonEdges = nil;
    BOOL shouldRecord = NO;
    NSString *captureReason = @"periodic_idle_sample";
    @synchronized (controller) {
        callbackCount = ++controller.diagnosticInputCallbacks;
        if (controller.diagnosticPhysicalButtonStates == nil) {
            controller.diagnosticPhysicalButtonStates = [NSMutableDictionary dictionary];
        }
        if ([changedElement isKindOfClass:[GCControllerButtonInput class]] && resolvedChangedElementName.length > 0) {
            GCControllerButtonInput *button = (GCControllerButtonInput *)changedElement;
            NSNumber *pressed = button.pressed ? @YES : @NO;
            NSNumber *previous = controller.diagnosticPhysicalButtonStates[resolvedChangedElementName];
            if ((previous != nil && previous.boolValue != pressed.boolValue) ||
                (previous == nil && pressed.boolValue)) {
                if (physicalButtonEdges == nil) physicalButtonEdges = [NSMutableArray array];
                [physicalButtonEdges addObject:@{@"physical_control": resolvedChangedElementName, @"pressed": pressed}];
            }
            controller.diagnosticPhysicalButtonStates[resolvedChangedElementName] = pressed;
        }

        BOOL hadMeaningfulInput = controller.diagnosticHadMeaningfulPhysicalInput;
        controller.diagnosticHadMeaningfulPhysicalInput = meaningfulInput;
        BOOL shouldRecordMeaningfulSample = meaningfulInput &&
            (controller.diagnosticLastMeaningfulStateLogTime == 0 ||
             now - controller.diagnosticLastMeaningfulStateLogTime >= 0.25);
        shouldRecord = physicalButtonEdges.count > 0 || shouldRecordMeaningfulSample ||
            (hadMeaningfulInput && !meaningfulInput) ||
            controller.diagnosticLastCallbackLogTime == 0 ||
            now - controller.diagnosticLastCallbackLogTime >= 2.0;
        if (physicalButtonEdges.count > 0) captureReason = @"physical_button_edge";
        else if (shouldRecordMeaningfulSample) captureReason = @"active_input_sample";
        else if (hadMeaningfulInput && !meaningfulInput) captureReason = @"input_returned_to_neutral";
        if (shouldRecord) controller.diagnosticLastCallbackLogTime = now;
        if (shouldRecordMeaningfulSample) controller.diagnosticLastMeaningfulStateLogTime = now;
    }
    if (!shouldRecord) return;

    NSMutableDictionary<NSString *, NSNumber *> *physicalButtonStates = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, id> *physicalAnalogValues = [NSMutableDictionary dictionary];
    [profile.buttons enumerateKeysAndObjectsUsingBlock:^(NSString *name, GCControllerButtonInput *button, BOOL *stop) {
        physicalButtonStates[name] = @(button.pressed);
        physicalAnalogValues[name] = @(button.value);
    }];
    [profile.dpads enumerateKeysAndObjectsUsingBlock:^(NSString *name, GCControllerDirectionPad *dpad, BOOL *stop) {
        physicalAnalogValues[name] = @[@(dpad.xAxis.value), @(dpad.yAxis.value)];
    }];

    NSMutableArray<NSDictionary<NSString *, id> *> *pressedControls = [NSMutableArray array];
    [buttonStates enumerateKeysAndObjectsUsingBlock:^(NSNumber *elementFlag, NSNumber *pressed, BOOL *stop) {
        if (pressed.boolValue) {
            [pressedControls addObject:@{
                @"logical_flag": elementFlag,
                @"logical_control": diagnosticLogicalControlName(elementFlag.integerValue)
            }];
        }
    }];

    NSMutableDictionary<NSString *, id> *fields = [NSMutableDictionary dictionaryWithDictionary:diagnosticCommonControllerFields(controller)];
    fields[@"source"] = source;
    fields[@"callback_count"] = @(callbackCount);
    fields[@"capture_reason"] = captureReason;
    fields[@"meaningful_input"] = @(meaningfulInput);
    fields[@"pressed_controls"] = pressedControls;
    fields[@"mapped_controls"] = diagnosticMappedControls(elementMap, profile);
    fields[@"logical_mapping_count"] = @(elementMap.count);
    fields[@"physical_button_states"] = physicalButtonStates;
    fields[@"physical_button_edges"] = physicalButtonEdges ?: @[];
    fields[@"physical_analog_values"] = physicalAnalogValues;
    fields[@"changed_physical_element"] = resolvedChangedElementName ?: @"";
    fields[@"changed_element_class"] = changedElement != nil ? NSStringFromClass(changedElement.class) : @"";
    @synchronized (controller) {
        fields[@"has_received_input"] = @(controller.hasReceivedInput);
        fields[@"waits_for_input_before_arrival"] = @(controller.waitsForInputBeforeArrival);
        fields[@"requires_button_release_after_order_reset"] = @(controller.requiresButtonReleaseAfterOrderReset);
        fields[@"input_order_generation"] = @(controller.inputOrderGeneration);
    }
    fields[@"left_stick"] = @[@(leftX), @(leftY)];
    fields[@"right_stick"] = @[@(rightX), @(rightY)];
    fields[@"triggers"] = @[@(leftTrigger), @(rightTrigger)];
    fields[@"controller_port_assignment"] = @"Port assignment occurs only after meaningful input; the first input requests the next free Sunshine port.";
    [ControllerDiagnostics recordEvent:@"controller_input_callback" fields:fields];
}

static void recordControllerInputWorkerDequeued(VoidController *controller, CFTimeInterval capturedAt) {
    CFTimeInterval now = CACurrentMediaTime();
    NSUInteger processedCount;
    NSUInteger callbackCount;
    BOOL shouldRecord;
    @synchronized (controller) {
        processedCount = ++controller.diagnosticInputSnapshotsProcessed;
        callbackCount = controller.diagnosticInputCallbacks;
        controller.diagnosticCurrentSnapshotCapturedAt = capturedAt;
        shouldRecord = controller.diagnosticLastWorkerLogTime == 0 || now - controller.diagnosticLastWorkerLogTime >= 2.0;
        if (shouldRecord) controller.diagnosticLastWorkerLogTime = now;
    }
    if (!shouldRecord) return;

    NSMutableDictionary<NSString *, id> *fields = [NSMutableDictionary dictionaryWithDictionary:diagnosticCommonControllerFields(controller)];
    fields[@"callback_count"] = @(callbackCount);
    fields[@"processed_snapshot_count"] = @(processedCount);
    fields[@"callback_to_worker_ms"] = @((now - capturedAt) * 1000.0);
    [ControllerDiagnostics recordEvent:@"controller_input_worker_dequeued" fields:fields];
}

static BOOL triggerValueIsDigitallyPressed(CGFloat value, BOOL wasPressed) {
    if (!isfinite(value)) return NO;
    CGFloat deadzone = ControllerUtil.controllerTriggerDeadzone;
    CGFloat threshold = wasPressed ? deadzone * 0.8 : deadzone;
    return fmin(fmax(value, 0), 1) > threshold;
}

static char controllerInputQueueSpecificKey;

static void dispatchControllerInputWork(dispatch_queue_t queue, dispatch_block_t work) {
    // GameController callbacks are delivered directly on this queue while streaming.
    // Run the snapshot there instead of adding another queue hop. Keep the fallback
    // for callbacks that arrive from other queues (for example, on older OS versions).
    if (dispatch_get_specific(&controllerInputQueueSpecificKey) == &controllerInputQueueSpecificKey) {
        work();
    } else {
        dispatch_async(queue, work);
    }
}

@interface ControllerSupport()

@property (assign,nonatomic) bool shallDisableGyroHotSwitch;
- (void) listenToGenericGCController:(GCController*)controller API_AVAILABLE(ios(16.0), tvos(16.0));
- (void) updateGyroSwitchForController:(VoidController*)controller buttonFlag:(int)buttonFlag pressed:(BOOL)pressed;
- (void) resetGyroSwitchForPlayerIndex:(NSInteger)playerIndex;
- (void) releaseControllerTouchpadContacts:(VoidController*)controller;
- (void) handleControllerTouchpad:(VoidController*)controller x:(float)x y:(float)y active:(BOOL)isActive index:(int)index;
- (BOOL) reportControllerArrivalLocked:(VoidController*)voidController;
- (nullable VoidController*) voidControllerForGamepadLocked:(GCController*)gamepad;
- (nullable VoidController*) voidControllerForStreamPlayerIndexLocked:(NSInteger)playerIndex;
- (BOOL) assignStreamPlayerIndexLocked:(VoidController*)voidController;
- (void) resetControllerOrder;

@end


@implementation ControllerSupport {
    id _controllerConnectObserver;
    id _controllerDisconnectObserver;
    id _mouseConnectObserver;
    id _mouseDisconnectObserver;
    id _keyboardConnectObserver;
    id _keyboardDisconnectObserver;
    
    NSLock *_controllerStreamLock;
    dispatch_queue_t _controllerInputQueue;
    NSMutableDictionary *_voidControllers;
    StreamConfiguration* _streamConfig;
    __weak id<ControllerSupportDelegate> _delegate;
    
    float accumulatedDeltaX;
    float accumulatedDeltaY;
    float accumulatedScrollX;
    float accumulatedScrollY;
    
    bool _controllerNavigationEnabled;

    float stickMaxOffset;
    float _leftStickMinOffset;
    float _rightStickMinOffset;

    OnScreenControls *_osc;
    VoidController *_oscController;
    TemporarySettings* tempSettings;
    OSCProfile* oscProfile;
    OSCProfilesManager* oscProfileMan;
#if !TARGET_OS_TV
    GameSirG8MFiRumbler *_gameSirG8MFiRumbler;
    KishiV3ProXLRumbler *_kishiRumbler;
#endif

#define EMULATING_SELECT     0x1
#define EMULATING_SPECIAL    0x2
    
    bool _oscEnabled;
    char _controllerNumbers;
    char _reservedControllerNumbers;
    bool _multiController;
    bool _swapABXYButtons;
    int _gyroMode;
    CGFloat _gyroSensitivity;
    bool _captureMouse;
    
    bool _controllerGyroSwitchEnabled;
    bool _isCleaningUp;
    atomic_bool _gyroEnabledFlag; // Read by motion timers and written by controller callbacks.
    bool _gyroToggleEnabled;
    int _controllerGyroSwitchToggle;
    int _controllerGyroSwitchHold;
    bool _reverseHoldButton;
    bool _controllerGyroSwitchTogglePressed;
    bool _controllerGyroSwitchHoldPressed;
    uint32_t _controllerGyroSwitchTogglePressedMask;
    uint32_t _controllerGyroSwitchHoldPressedMask;
    ControllerGyroSwitchMode _gyroSwitchMode;

    uint64_t _authoredHapticsGeneration;

    __weak MotionHandler* motionHandler;
}

+(ControllerSupport*) sharedInstance
{
    return VLSharedControllerSupport;
}

// UPDATE_BUTTON_FLAG(controller, flag, pressed)
#define UPDATE_BUTTON_FLAG(controller, x, y) \
((y) ? [self setButtonFlag:controller flags:x] : [self clearButtonFlag:controller flags:x])

#define MAX_MAGNITUDE(x, y) (abs(x) > abs(y) ? (x) : (y))

-(void) applyPhysicalControllerRumble:(VoidController*)controller lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor
{
#if !TARGET_OS_TV
    switch (controller.hardware) {
        case ControllerHardwareRazerKishi:
            [_kishiRumbler setLowFrequencyMotor:lowFreqMotor highFrequencyMotor:highFreqMotor];
            return;
        case ControllerHardwareG8PlusMFi:
            [_gameSirG8MFiRumbler setLowFrequencyMotor:lowFreqMotor highFrequencyMotor:highFreqMotor];
            return;
        default:
            break;
    }
#endif

    [controller.lowFreqMotor setMotorAmplitude:lowFreqMotor];
    [controller.highFreqMotor setMotorAmplitude:highFreqMotor];
}

-(void) rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor
{
    [_controllerStreamLock lock];
    VoidController* voidController = [self voidControllerForStreamPlayerIndexLocked:controllerNumber];
    [_controllerStreamLock unlock];
    
    HapticEnginePreference preference = tempSettings.hapticEngine.intValue;
        
    if (voidController == nil && controllerNumber == 0 && _oscEnabled) {
        // no physical controller connected:
        if(preference != RumbleOff){
            [_oscController.lowFreqMotor setMotorAmplitude:lowFreqMotor];
            [_oscController.highFreqMotor setMotorAmplitude:highFreqMotor];
        }
    }
    
    if (voidController == nil) {
        // No connected controller for this player
        return;
    }

    /*
    NSLog(@"[G8Rumble] rumble request controller=%hu low=%hu high=%hu preference=%ld vendor=%@",
          controllerNumber,
          lowFreqMotor,
          highFreqMotor,
          (long)preference,
          voidController.gamepad.vendorName);
     */
    
    // physical controller connected:
    switch (preference) {
        case HapticEngineAuto:
            // if controller has no haptic profile, it already falled bakc to device engine
            [self applyPhysicalControllerRumble:voidController lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
            break;
        case RumbleDevice:
            [self applyPhysicalControllerRumble:voidController lowFreqMotor:0 highFreqMotor:0];
            [_oscController.lowFreqMotor setMotorAmplitude:lowFreqMotor];
            [_oscController.highFreqMotor setMotorAmplitude:highFreqMotor];
            break;
        case LeftRightSwapped:
            [self applyPhysicalControllerRumble:voidController lowFreqMotor:highFreqMotor highFreqMotor:lowFreqMotor];
            break;
        case RumbleOff:
            [self applyPhysicalControllerRumble:voidController lowFreqMotor:0 highFreqMotor:0];
            break;
        default:
            break;
    }
}

-(void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger
{
    [_controllerStreamLock lock];
    VoidController* controller = [self voidControllerForStreamPlayerIndexLocked:controllerNumber];
    [_controllerStreamLock unlock];
    if (controller == nil && controllerNumber == 0 && _oscEnabled) {
        // TODO: Trigger rumble emulation for OSC
    }
    if (controller == nil) {
        // No connected controller for this player
        return;
    }
    [controller.leftTriggerMotor setMotorAmplitude:leftTrigger];
    [controller.rightTriggerMotor setMotorAmplitude:rightTrigger];
}

- (bool)isLandscapeNow {
    return CGRectGetWidth([[UIScreen mainScreen]bounds]) > CGRectGetHeight([[UIScreen mainScreen]bounds]);
}

#if !TARGET_OS_TV
- (UIInterfaceOrientation)currentInterfaceOrientation
{
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }

            if (windowScene.interfaceOrientation != UIInterfaceOrientationUnknown) {
                return windowScene.interfaceOrientation;
            }
        }

        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateUnattached) {
                continue;
            }

            if (windowScene.interfaceOrientation != UIInterfaceOrientationUnknown) {
                return windowScene.interfaceOrientation;
            }
        }
    }

    return UIApplication.sharedApplication.statusBarOrientation;
}
#endif

-(void)updateTimerStateForController:(VoidController* )voidController{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateTimerStateForController:voidController];
        });
        return;
    }

    if (voidController == nil) {
        [self stopTimerForController:voidController];
        return;
    }

    if (voidController.gamepad != nil &&
        (!voidController.reportedArrival || voidController.streamPlayerIndex < 0)) {
        [voidController.accelTimer invalidate];
        voidController.accelTimer = nil;
        [voidController.gyroTimer invalidate];
        voidController.gyroTimer = nil;
#if !TARGET_OS_TV
        [voidController.motionManager stopDeviceMotionUpdates];
#endif
        if (@available(iOS 14.0, tvOS 14.0, *)) {
            voidController.gamepad.motion.sensorsActive = NO;
        }
        return;
    }

    if (voidController.reportRateHz == 0) {
        [self stopTimerForController:voidController];
        return;
    }

    // if (@available(iOS 14.0, tvOS 14.0, *)) {
    if(_gyroMode == GyroModeOff){
        [self stopTimerForController:voidController];
        return;
    }
    if([ControllerUtil hasControllerAccelerometer:voidController.gamepad]) {
        [voidController.motionTypes addObject:@(LI_MOTION_TYPE_ACCEL)];
    }
    if (@available(iOS 14.0, tvOS 14.0, *)) if(voidController.gamepad.motion.hasRotationRate){
        [voidController.motionTypes addObject:@(LI_MOTION_TYPE_GYRO)];
    }

    for(NSNumber* motionTypeObj in voidController.motionTypes){
        uint8_t motionType = motionTypeObj.intValue;

#if !TARGET_OS_TV //tvOS has no device motion
        if(voidController == _oscController){
            //Player has no controller *or* no motion for controller 1 *or* wants to override controller 1 motion with device motion
            if(!voidController.motionManager) {
                voidController.motionManager = [[CMMotionManager alloc] init];
            }
            
            switch (motionType) {
                case LI_MOTION_TYPE_ACCEL: {
                    [voidController.accelTimer invalidate];
                    voidController.accelTimer = nil;
                    // Reset the last motion sample
                    CMAcceleration emptyDeviceAccelSample = {};
                    voidController.lastDeviceAccelSample = emptyDeviceAccelSample;
                    voidController.motionManager.deviceMotionUpdateInterval = 1.0 / voidController.reportRateHz;
                    [voidController.motionManager startDeviceMotionUpdates];
                    {NSLog(@"setup device built-in accelTimer");
                        voidController.hasAccelerometer = YES;
                        voidController.accelTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / voidController.reportRateHz repeats:YES block:^(NSTimer *timer) {
                            CMAcceleration deviceAccelSample = voidController.motionManager.deviceMotion.userAcceleration;
                            //userAcceleration does not contain gravity, add gravity to x, y and z values:
                            deviceAccelSample.x += voidController.motionManager.deviceMotion.gravity.x;
                            deviceAccelSample.y += voidController.motionManager.deviceMotion.gravity.y;
                            deviceAccelSample.z += voidController.motionManager.deviceMotion.gravity.z;
                            // NSLog(@"sending device accel %f", CACurrentMediaTime());

                            UIInterfaceOrientation interfaceOrientation = [self currentInterfaceOrientation];
                            CMAcceleration mappedDeviceAccelSample = {};
                            switch (interfaceOrientation) {
                                case UIInterfaceOrientationLandscapeLeft:
                                    mappedDeviceAccelSample.x = deviceAccelSample.y * -9.80665f;
                                    mappedDeviceAccelSample.y = deviceAccelSample.z * -9.80665f;
                                    mappedDeviceAccelSample.z = deviceAccelSample.x * -9.80665f;
                                    break;
                                case UIInterfaceOrientationLandscapeRight:
                                    mappedDeviceAccelSample.x = deviceAccelSample.y * 9.80665f;
                                    mappedDeviceAccelSample.y = deviceAccelSample.z * -9.80665f;
                                    mappedDeviceAccelSample.z = deviceAccelSample.x * 9.80665f;
                                    break;
                                case UIInterfaceOrientationPortrait:
                                    mappedDeviceAccelSample.x = deviceAccelSample.x * -9.80665f;
                                    mappedDeviceAccelSample.y = deviceAccelSample.z * -9.80665f;
                                    mappedDeviceAccelSample.z = deviceAccelSample.y * 9.80665f;
                                    break;
                                case UIInterfaceOrientationPortraitUpsideDown:
                                    mappedDeviceAccelSample.x = deviceAccelSample.x * 9.80665f;
                                    mappedDeviceAccelSample.y = deviceAccelSample.z * -9.80665f;
                                    mappedDeviceAccelSample.z = deviceAccelSample.y * -9.80665f;
                                    break;
                                default:
                                    mappedDeviceAccelSample.x = deviceAccelSample.y * -9.80665f;
                                    mappedDeviceAccelSample.y = deviceAccelSample.z * -9.80665f;
                                    mappedDeviceAccelSample.z = deviceAccelSample.x * -9.80665f;
                                    break;
                            }

                            // Don't send duplicate samples after orientation remapping.
                            CMAcceleration lastDeviceAccelSample = voidController.lastDeviceAccelSample;
                            if (memcmp(&mappedDeviceAccelSample, &lastDeviceAccelSample, sizeof(mappedDeviceAccelSample)) == 0) {
                                return;
                            }
                            voidController.lastDeviceAccelSample = mappedDeviceAccelSample;
                            
                            // Convert g to m/s^2
                            LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                        LI_MOTION_TYPE_ACCEL,
                                                        mappedDeviceAccelSample.x,
                                                        mappedDeviceAccelSample.y,
                                                        mappedDeviceAccelSample.z);
                        }];}
                    break;
                }
                case LI_MOTION_TYPE_GYRO: {
                    [voidController.gyroTimer invalidate];
                    voidController.gyroTimer = nil;
                    
                    // Reset the last motion sample
                    CMRotationRate emptyDeviceGyroSample = {};
                    voidController.lastDeviceGyroSample = emptyDeviceGyroSample;
                    [voidController.motionManager startDeviceMotionUpdates];
                    
                    NSLog(@"setup device built-in gyro gyroTimer");
                    voidController.hasGyroscope = YES;
                    voidController.gyroTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / voidController.reportRateHz repeats:YES block:^(NSTimer *timer) {
                        
                        // Don't send duplicate samples
                        CMRotationRate lastDeviceGyroSample = voidController.lastDeviceGyroSample;
                        CMRotationRate deviceGyroSample = voidController.motionManager.deviceMotion.rotationRate;
                        if (memcmp(&deviceGyroSample, &lastDeviceGyroSample, sizeof(deviceGyroSample)) == 0) {
                                return;
                        }
                        voidController.lastDeviceGyroSample = deviceGyroSample;
                        
                        // Convert rad/s to deg/s
                        
                        UIInterfaceOrientation interfaceOrientation = [self currentInterfaceOrientation];
                        
                        switch (interfaceOrientation) {
                            case UIInterfaceOrientationLandscapeLeft:
                                LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                            LI_MOTION_TYPE_GYRO,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.y * 57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.z * 57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.x * 57.2957795f * self->_gyroSensitivity : 0);
                                break;
                            case UIInterfaceOrientationLandscapeRight:
                                LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                            LI_MOTION_TYPE_GYRO,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.y * -57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.z * 57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.x * -57.2957795f * self->_gyroSensitivity : 0);
                                break;
                            case UIInterfaceOrientationPortrait:
                                LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                            LI_MOTION_TYPE_GYRO,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.x * 57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.z * 57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.y * -57.2957795f * self->_gyroSensitivity : 0);
                                break;
                            case UIInterfaceOrientationPortraitUpsideDown:
                                LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                            LI_MOTION_TYPE_GYRO,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.x * -57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.z * 57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.y * 57.2957795f * self->_gyroSensitivity : 0);
                                break;
                            default:
                                LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                            LI_MOTION_TYPE_GYRO,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.y * 57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.z * 57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.x * 57.2957795f * self->_gyroSensitivity : 0);
                                break;
                        }
                        
                        /*
                        if(UIApplication.sharedApplication.windows.firstObject.windowScene.interfaceOrientation == 4){//check for landscape left or landscape right
                            LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                        LI_MOTION_TYPE_GYRO,
                                                        self->_gyroEnabledFlag ? deviceGyroSample.y * 57.2957795f * self->_gyroSensitivity : 0,
                                                        self->_gyroEnabledFlag ? deviceGyroSample.z * 57.2957795f * self->_gyroSensitivity : 0,
                                                        self->_gyroEnabledFlag ? deviceGyroSample.x * 57.2957795f * self->_gyroSensitivity : 0);
                        }
                        else{
                            LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                        LI_MOTION_TYPE_GYRO,
                                                        self->_gyroEnabledFlag ? deviceGyroSample.y * -57.2957795f * self->_gyroSensitivity : 0,
                                                        self->_gyroEnabledFlag ? deviceGyroSample.z * 57.2957795f * self->_gyroSensitivity : 0,
                                                        self->_gyroEnabledFlag ? deviceGyroSample.x * -57.2957795f * self->_gyroSensitivity : 0);
                        }
                        */
                    }];
                    break;
                }
            }
        }
        else
#endif
        {
            // NSLog(@"controller obj timer update: controller timer ");
            if (@available(iOS 14.0, tvOS 14.0, *)) {
                switch (motionType) {
                    case LI_MOTION_TYPE_ACCEL:
                        [voidController.accelTimer invalidate];
                        voidController.accelTimer = nil;
                        
                        // if (voidController.reportRateHz && voidController.gamepad.motion.hasGravityAndUserAcceleration) {
                        if (voidController.reportRateHz) {
                            // Reset the last motion sample
                            GCAcceleration emptyAccelSample = {};
                            voidController.lastAccelSample = emptyAccelSample;
                            void (^setupAccelTimer)(void) = ^{
                                voidController.hasAccelerometer = YES;
                                voidController.accelTimer =
                                [NSTimer scheduledTimerWithTimeInterval:1.0 / voidController.reportRateHz
                                                                repeats:YES
                                                                  block:^(NSTimer *timer) {
                                    GCAcceleration lastAccelSample = voidController.lastAccelSample;
                                    GCAcceleration accelSample = voidController.gamepad.motion.acceleration;
                                    if (memcmp(&accelSample, &lastAccelSample, sizeof(accelSample)) == 0) {
                                        return;
                                    }
                                    // NSLog(@"sending controller accel %f", CACurrentMediaTime());
                                    
                                    voidController.lastAccelSample = accelSample;
                                    
                                    LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                                LI_MOTION_TYPE_ACCEL,
                                                                accelSample.x * -9.80665f,
                                                                accelSample.y * -9.80665f,
                                                                accelSample.z * -9.80665f);
                                }];
                            };
                            if ([NSThread isMainThread]) {
                                setupAccelTimer();
                            } else {
                                dispatch_async(dispatch_get_main_queue(), setupAccelTimer);
                            }
                        }
                        break;
                        
                    case LI_MOTION_TYPE_GYRO:
                        [voidController.gyroTimer invalidate];
                        voidController.gyroTimer = nil;
                        
                        if (voidController.reportRateHz && voidController.gamepad.motion.hasRotationRate) {
                            // Reset the last motion sample
                            GCRotationRate emptyGyroSample = {};
                            voidController.lastGyroSample = emptyGyroSample;
                            //dispatch_sync(dispatch_get_main_queue(), ^{
                            void (^setupGyroTimer)(void) = ^{
                                voidController.hasGyroscope = YES;
                                voidController.gyroTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / voidController.reportRateHz repeats:YES block:^(NSTimer *timer) {
                                    // Don't send duplicate samples
                                    GCRotationRate lastGyroSample = voidController.lastGyroSample;
                                    GCRotationRate gyroSample = voidController.gamepad.motion.rotationRate;
                                    if (memcmp(&gyroSample, &lastGyroSample, sizeof(gyroSample)) == 0) {
                                        return;
                                    }
                                    voidController.lastGyroSample = gyroSample;
                                    
                                    // Convert rad/s to deg/s
                                    // NSLog(@"sending controller gyro data, gyroSample data 00: %f, playerIndex: %ld, obj: %@",gyroSample.x, (long)voidController.gamepad.playerIndex, voidController);
                                    LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                                LI_MOTION_TYPE_GYRO,
                                                                self->_gyroEnabledFlag ? gyroSample.x * 57.2957795f * self->_gyroSensitivity : 0,
                                                                self->_gyroEnabledFlag ? gyroSample.z * 57.2957795f * self->_gyroSensitivity : 0,
                                                                self->_gyroEnabledFlag ? gyroSample.y * -57.2957795f * self->_gyroSensitivity : 0);
                                }];
                            };
                            if ([NSThread isMainThread]) setupGyroTimer();
                            else dispatch_async(dispatch_get_main_queue(), setupGyroTimer);
                        }
                        break;
                }
            }
        }
    }
    
    NSLog(@"controller obj timer, motionTypes: %lu", (unsigned long)voidController.motionTypes.count);

    // Set the motion sensor state if they require manual activation
    [self updateSensorSateForController:voidController];
    // NSLog(@"sensor active: %d", voidController.gamepad.motion.sensorsActive);
}

- (void)updateSensorSateForController:(VoidController* )voidController{
    if (@available(iOS 14.0, *)) {
        if (voidController.gamepad.motion.sensorsRequireManualActivation) {
            if ((voidController.hasGyroscope || voidController.hasAccelerometer) && _gyroMode != GyroModeOff) {
                voidController.gamepad.motion.sensorsActive = YES;
            }
            else {
                voidController.gamepad.motion.sensorsActive = NO;
            }
        }
    }
}

- (void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
        });
        return;
    }

    //if (@available(iOS 14.0, tvOS 14.0, *)) {
        NSLog(@"gyroMode: %ld", (long)_gyroMode);
        
        [_controllerStreamLock lock];
        VoidController* voidController = [self voidControllerForStreamPlayerIndexLocked:controllerNumber];
        [_controllerStreamLock unlock];
        //using device motion
        if (voidController == nil || _gyroMode == AlwaysDevice) {
            // No connected controller for this player, use the _oscController instead
            voidController = _oscController;
            if(!voidController.motionTypes){
                voidController.motionTypes = [[NSMutableSet alloc] init];
            }
            if (reportRateHz == 0) {
                [voidController.motionTypes removeObject:@(motionType)];
            }
            else {
                [voidController.motionTypes addObject:@(motionType)];
            }
            
            voidController.hasGyroscope = NO;
            voidController.hasAccelerometer = NO;
        }
        
        voidController.reportRateHz = reportRateHz;
        voidController.controllerNumber = controllerNumber;

        if (reportRateHz == 0) {
            [self stopTimerForController:voidController];
        }
        else if(voidController == _oscController) {
            [self updateTimerStateForController:voidController];
        }
    //}
}

-(void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b {
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        [_controllerStreamLock lock];
        VoidController* controller = [self voidControllerForStreamPlayerIndexLocked:controllerNumber];
        [_controllerStreamLock unlock];
        if (controller == nil) {
            // No connected controller for this player
            return;
        }
        
        if (controller.gamepad.light == nil) {
            // No LED control supported for this controller
            return;
        }

        controller.gamepad.light.color = [[GCColor alloc] initWithRed:(r / 255.0f) green:(g / 255.0f) blue:(b / 255.0f)];
    }
}

-(void) setAdaptiveTriggers:(uint16_t)controllerNumber eventFlags:(uint8_t)eventFlags
                    typeLeft:(uint8_t)typeLeft typeRight:(uint8_t)typeRight
                        left:(const uint8_t*)left right:(const uint8_t*)right {
    // Only the flagged triggers are being programmed; the other side is stale.
    bool applyLeft = (eventFlags & DS_EFFECT_LEFT_TRIGGER) != 0;
    bool applyRight = (eventFlags & DS_EFFECT_RIGHT_TRIGGER) != 0;
    if (!applyLeft && !applyRight) {
        return;
    }

    // The callback-owned buffers are only valid for this call. Copy them before
    // dispatching to the main queue; decoding in the async block would read stale
    // data, especially for the right trigger.
    NSData *leftPayload = applyLeft ? [NSData dataWithBytes:left length:DS_EFFECT_PAYLOAD_SIZE] : nil;
    NSData *rightPayload = applyRight ? [NSData dataWithBytes:right length:DS_EFFECT_PAYLOAD_SIZE] : nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 14.5, tvOS 14.5, *)) {
            [self->_controllerStreamLock lock];
            VoidController* controller = [self voidControllerForStreamPlayerIndexLocked:controllerNumber];
            [self->_controllerStreamLock unlock];
            if (controller == nil) {
                Log(LOG_W, @"Ignoring adaptive trigger effect for missing gamepad %u", controllerNumber);
                return;
            }

            if (![controller.gamepad.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
                Log(LOG_W, @"Ignoring adaptive trigger effect for non-DualSense gamepad %u", controllerNumber);
                return;
            }

            GCDualSenseGamepad* dualSense = (GCDualSenseGamepad*)controller.gamepad.extendedGamepad;
            if (applyLeft) {
                [ControllerUtil applyAdaptiveTrigger:dualSense.leftTrigger
                                                type:typeLeft
                                             payload:leftPayload];
            }
            if (applyRight) {
                [ControllerUtil applyAdaptiveTrigger:dualSense.rightTrigger
                                                type:typeRight
                                             payload:rightPayload];
            }
        }
    });
}

-(void) renderDualSenseHaptics:(uint16_t)controllerNumber
                 leftAmplitude:(float)leftAmplitude
                 leftSharpness:(float)leftSharpness
                 leftTransient:(float)leftTransient
                rightAmplitude:(float)rightAmplitude
                rightSharpness:(float)rightSharpness
                rightTransient:(float)rightTransient
                   delaySeconds:(double)delaySeconds {
    __block uint64_t generation;
    @synchronized(self) {
        generation = _authoredHapticsGeneration;
    }
    dispatch_block_t renderBlock = ^{
        @synchronized(self) {
            if (generation != self->_authoredHapticsGeneration) {
                return;
            }
        }
        if (@available(iOS 14.5, tvOS 14.5, *)) {
            [self->_controllerStreamLock lock];
            VoidController* controller = [self voidControllerForStreamPlayerIndexLocked:controllerNumber];
            [self->_controllerStreamLock unlock];
            if (controller == nil ||
                ![controller.gamepad.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
                return;
            }

            [controller.lowFreqMotor setAuthoredAmplitude:leftAmplitude
                                                sharpness:leftSharpness
                                        transientStrength:leftTransient];
            [controller.highFreqMotor setAuthoredAmplitude:rightAmplitude
                                                 sharpness:rightSharpness
                                         transientStrength:rightTransient];
        }
    };

    if (delaySeconds > 0.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySeconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), renderBlock);
    }
    else {
        dispatch_async(dispatch_get_main_queue(), renderBlock);
    }
}

-(BOOL) hasDualSenseController:(uint16_t)controllerNumber {
    __block BOOL result = NO;
    dispatch_block_t checkBlock = ^{
        if (@available(iOS 14.5, tvOS 14.5, *)) {
            [self->_controllerStreamLock lock];
            VoidController* controller = [self voidControllerForStreamPlayerIndexLocked:controllerNumber];
            [self->_controllerStreamLock unlock];
            result = controller != nil &&
                [controller.gamepad.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]];
        }
    };

    if ([NSThread isMainThread]) {
        checkBlock();
    }
    else {
        dispatch_sync(dispatch_get_main_queue(), checkBlock);
    }
    return result;
}

-(void) renderDeviceDualSenseHaptics:(uint16_t)controllerNumber
                        leftAmplitude:(float)leftAmplitude
                        leftSharpness:(float)leftSharpness
                        leftTransient:(float)leftTransient
                       rightAmplitude:(float)rightAmplitude
                       rightSharpness:(float)rightSharpness
                       rightTransient:(float)rightTransient
                          delaySeconds:(double)delaySeconds {
    __block uint64_t generation;
    @synchronized(self) {
        generation = _authoredHapticsGeneration;
    }
    dispatch_block_t renderBlock = ^{
        @synchronized(self) {
            if (generation != self->_authoredHapticsGeneration) {
                return;
            }
        }
        if (@available(iOS 14.0, tvOS 14.0, *)) {
            [self->_oscController.lowFreqMotor setAuthoredAmplitude:leftAmplitude
                                                          sharpness:leftSharpness
                                                  transientStrength:leftTransient];
            [self->_oscController.highFreqMotor setAuthoredAmplitude:rightAmplitude
                                                           sharpness:rightSharpness
                                                   transientStrength:rightTransient];
        }
    };

    if (delaySeconds > 0.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySeconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), renderBlock);
    }
    else {
        dispatch_async(dispatch_get_main_queue(), renderBlock);
    }
}

-(void) cancelScheduledDualSenseHaptics {
    @synchronized(self) {
        _authoredHapticsGeneration++;
    }
}

-(void) updateLeftStick:(VoidController*)controller x:(short)x y:(short)y
{
    @synchronized(controller) {
        controller.lastLeftStickX = x;
        controller.lastLeftStickY = y;
    }
}

-(void) updateRightStick:(VoidController*)controller x:(short)x y:(short)y
{
    @synchronized(controller) {
        controller.lastRightStickX = x;
        controller.lastRightStickY = y;
    }
}

-(void) updateLeftTrigger:(VoidController*)controller left:(unsigned char)left
{
    @synchronized(controller) {
        controller.lastLeftTrigger = left;
    }
}

-(void) updateRightTrigger:(VoidController*)controller right:(unsigned char)right
{
    @synchronized(controller) {
        controller.lastRightTrigger = right;
    }
}

-(void) updateTriggers:(VoidController*) controller left:(unsigned char)left right:(unsigned char)right
{
    @synchronized(controller) {
        controller.lastLeftTrigger = left;
        controller.lastRightTrigger = right;
    }
}

-(void) handleSpecialCombosReleased:(VoidController*)controller releasedButtons:(int)releasedButtons
{
    if ((controller.emulatingButtonFlags & EMULATING_SELECT) && (releasedButtons & (LB_FLAG | PLAY_FLAG))) {
        controller.lastButtonFlags &= ~BACK_FLAG;
        controller.emulatingButtonFlags &= ~EMULATING_SELECT;
    }
    
    if (controller.emulatingButtonFlags & EMULATING_SPECIAL) {
        // If Select is emulated, we use RB+Start to emulate special, otherwise we use Start+Select
        if (controller.supportedEmulationFlags & EMULATING_SELECT) {
            if (releasedButtons & (RB_FLAG | PLAY_FLAG)) {
                controller.lastButtonFlags &= ~SPECIAL_FLAG;
                controller.emulatingButtonFlags &= ~EMULATING_SPECIAL;
            }
        }
        else {
            if (releasedButtons & (BACK_FLAG | PLAY_FLAG)) {
                controller.lastButtonFlags &= ~SPECIAL_FLAG;
                controller.emulatingButtonFlags &= ~EMULATING_SPECIAL;
            }
        }
    }
}

-(void) handleSpecialCombosPressed:(VoidController*)controller pressedButtons:(int)pressedButtons
{
    // Special button combos for select and special
    if (controller.lastButtonFlags & PLAY_FLAG) {
        // If LB and start are down, trigger select
        if (controller.lastButtonFlags & LB_FLAG) {
            if (controller.supportedEmulationFlags & EMULATING_SELECT) {
                controller.lastButtonFlags |= BACK_FLAG;
                controller.lastButtonFlags &= ~(pressedButtons & (PLAY_FLAG | LB_FLAG));
                controller.emulatingButtonFlags |= EMULATING_SELECT;
            }
        }
        else if (controller.supportedEmulationFlags & EMULATING_SPECIAL) {
            // If Select is emulated too, use RB+Start to emulate special
            if (controller.supportedEmulationFlags & EMULATING_SELECT) {
                if (controller.lastButtonFlags & RB_FLAG) {
                    controller.lastButtonFlags |= SPECIAL_FLAG;
                    controller.lastButtonFlags &= ~(pressedButtons & (PLAY_FLAG | RB_FLAG));
                    controller.emulatingButtonFlags |= EMULATING_SPECIAL;
                }
            }
            else {
                // If Select is physical, use Start+Select to emulate special
                if (controller.lastButtonFlags & BACK_FLAG) {
                    controller.lastButtonFlags |= SPECIAL_FLAG;
                    controller.lastButtonFlags &= ~(pressedButtons & (PLAY_FLAG | BACK_FLAG));
                    controller.emulatingButtonFlags |= EMULATING_SPECIAL;
                }
            }
        }
    }
}

-(void) updateButtonFlags:(VoidController*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags = flags;
        
        // This must be called before handleSpecialCombosPressed
        // because we clear the original button flags there
        int releasedButtons = (controller.lastButtonFlags ^ flags) & ~flags;
        int pressedButtons = (controller.lastButtonFlags ^ flags) & flags;
        
        [self handleSpecialCombosReleased:controller releasedButtons:releasedButtons];
        
        [self handleSpecialCombosPressed:controller pressedButtons:pressedButtons];
    }
}

-(void) setButtonFlag:(VoidController*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags |= flags;
        [self handleSpecialCombosPressed:controller pressedButtons:flags];
    }
}

-(void) clearButtonFlag:(VoidController*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags &= ~flags;
        [self handleSpecialCombosReleased:controller releasedButtons:flags];
    }
}

-(uint16_t) getActiveGamepadMask
{
    return (_multiController ? _controllerNumbers : 1) | (_oscEnabled ? 1 : 0);
}

// _voidControllers is keyed by a local bookkeeping index. The Sunshine port is
// deliberately separate because it is assigned only after a button press.
- (VoidController*)voidControllerForGamepadLocked:(GCController*)gamepad
{
    for (VoidController* controller in _voidControllers.allValues) {
        if (controller.gamepad == gamepad) return controller;
    }
    return nil;
}

- (VoidController*)voidControllerForStreamPlayerIndexLocked:(NSInteger)playerIndex
{
    for (VoidController* controller in _voidControllers.allValues) {
        if (controller.streamPlayerIndex == playerIndex && controller.reportedArrival) return controller;
    }
    return nil;
}

- (BOOL)assignStreamPlayerIndexLocked:(VoidController*)voidController
{
    if (!_multiController) {
        voidController.streamPlayerIndex = 0;
        _reservedControllerNumbers |= 1;
        return YES;
    }

    if (voidController.streamPlayerIndex >= 0) return YES;

    for (int playerIndex = 0; playerIndex < 4; playerIndex++) {
        int slotBit = 1 << playerIndex;
        if (((_controllerNumbers | _reservedControllerNumbers) & slotBit) == 0) {
            voidController.streamPlayerIndex = playerIndex;
            _reservedControllerNumbers |= slotBit;
            return YES;
        }
    }

    Log(LOG_W, @"No free Sunshine controller port for %@", voidController.gamepad.vendorName ?: @"controller");
    CFTimeInterval now = CACurrentMediaTime();
    BOOL shouldRecordFailure = NO;
    @synchronized (voidController) {
        shouldRecordFailure = voidController.diagnosticLastPortAssignmentFailureTime == 0 ||
            now - voidController.diagnosticLastPortAssignmentFailureTime >= 3.0;
        if (shouldRecordFailure) voidController.diagnosticLastPortAssignmentFailureTime = now;
    }
    if (shouldRecordFailure) {
        NSMutableDictionary<NSString *, id> *fields = [NSMutableDictionary dictionaryWithDictionary:diagnosticCommonControllerFields(voidController)];
        fields[@"active_port_mask"] = @(_controllerNumbers);
        fields[@"reserved_port_mask"] = @(_reservedControllerNumbers);
        [ControllerDiagnostics recordEvent:@"controller_port_assignment_failed" fields:fields];
    }
    return NO;
}

- (void)resetControllerOrder
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self resetControllerOrder];
        });
        return;
    }

    // Drain earlier snapshots, then invalidate any callback that was captured
    // before this reset but reaches the serial worker afterward.
    dispatch_sync(_controllerInputQueue, ^{});
    for (VoidController* controller in _voidControllers.allValues) {
        [self stopTimerForController:controller];
        [self cleanupControllerBattery:controller];
    }
    [self stopTimerForController:_oscController];
    [_controllerStreamLock lock];
    if (_isCleaningUp) {
        [_controllerStreamLock unlock];
        return;
    }

    uint16_t previouslyActiveMask = [self getActiveGamepadMask];
    [ControllerDiagnostics recordEvent:@"controller_order_reset" fields:@{
        @"previous_active_port_mask": @(previouslyActiveMask),
        @"endpoint_count": @(_voidControllers.count)
    }];
    _controllerNumbers = 0;
    _reservedControllerNumbers = 0;
    for (VoidController* controller in _voidControllers.allValues) {
        BOOL hasButtonHeld = NO;
        if (@available(iOS 14.0, tvOS 14.0, *)) {
            NSDictionary<NSString *, GCControllerButtonInput *> *buttons = controller.gamepad.physicalInputProfile.buttons;
            for (NSString *buttonName in buttons) {
                GCControllerButtonInput *button = buttons[buttonName];
                BOOL isTrigger = [buttonName isEqualToString:GCInputLeftTrigger] ||
                    [buttonName isEqualToString:GCInputRightTrigger];
                BOOL isPressed = isTrigger
                    ? triggerValueIsDigitallyPressed(button.value, NO)
                    : button.pressed;
                if (isPressed) {
                    hasButtonHeld = YES;
                    break;
                }
            }
        }

        @synchronized (controller) {
            controller.inputOrderGeneration++;
            controller.streamPlayerIndex = -1;
            controller.reportedArrival = NO;
            controller.hasReceivedInput = NO;
            controller.didLogArrivalDeferred = NO;
            controller.requiresButtonReleaseAfterOrderReset = hasButtonHeld;
            controller.radialMenuButtonPressed = NO;
            controller.leftTriggerDigitallyPressed = NO;
            controller.rightTriggerDigitallyPressed = NO;
            controller.lastButtonFlags = 0;
            controller.emulatingButtonFlags = 0;
            controller.lastLeftTrigger = 0;
            controller.lastRightTrigger = 0;
            controller.lastLeftStickX = 0;
            controller.lastLeftStickY = 0;
            controller.lastRightStickX = 0;
            controller.lastRightStickY = 0;
            controller.primaryTouch = (controller_touch_context_t){0};
            controller.secondaryTouch = (controller_touch_context_t){0};
            controller.mergedWithController = nil;
        }
    }

    @synchronized (_oscController) {
        _oscController.reportedArrival = NO;
        _oscController.lastButtonFlags = 0;
        _oscController.emulatingButtonFlags = 0;
        _oscController.lastLeftTrigger = 0;
        _oscController.lastRightTrigger = 0;
        _oscController.lastLeftStickX = 0;
        _oscController.lastLeftStickY = 0;
        _oscController.lastRightStickX = 0;
        _oscController.lastRightStickY = 0;
        _oscController.mergedWithController = nil;
    }

    // Drop every old host association. The next button press announces a fresh
    // controller on the first free Sunshine port.
    int result = 0;
    for (int playerIndex = 0; playerIndex < 16; playerIndex++) {
        if (previouslyActiveMask & (1 << playerIndex)) {
            int sendResult = LiSendMultiControllerEvent(playerIndex, 0, 0, 0, 0, 0, 0, 0, 0);
            if (sendResult != 0) result = sendResult;
        }
    }
    [_controllerStreamLock unlock];
    [ControllerUtil setStreamingPrimaryController:nil];
    Log(LOG_I, @"Controller order reset; cleared host controller ports (send result %d)", result);
    [_delegate gamepadPresenceChanged];
}

-(void) updateFinished:(VoidController*)controller
{
    BOOL exitRequested = NO;
    
    [_controllerStreamLock lock];
    @synchronized(controller) {
        // Handle Start+Select+L1+R1 gamepad quit combo
        if (controller.lastButtonFlags == (PLAY_FLAG | BACK_FLAG | LB_FLAG | RB_FLAG)) {
            controller.lastButtonFlags = 0;
            exitRequested = YES;
        }
        
        // Only send controller events if we successfully reported controller arrival
        if ([self reportControllerArrivalLocked:controller]) {
            uint32_t buttonFlags = controller.lastButtonFlags;
            uint8_t leftTrigger = controller.lastLeftTrigger;
            uint8_t rightTrigger = controller.lastRightTrigger;
            int16_t leftStickX = controller.lastLeftStickX;
            int16_t leftStickY = controller.lastLeftStickY;
            int16_t rightStickX = controller.lastRightStickX;
            int16_t rightStickY = controller.lastRightStickY;
            
            // If this is merged with another controller, combine the inputs
            if (controller.mergedWithController) {
                buttonFlags |= controller.mergedWithController.lastButtonFlags;
                leftTrigger = MAX(leftTrigger, controller.mergedWithController.lastLeftTrigger);
                rightTrigger = MAX(rightTrigger, controller.mergedWithController.lastRightTrigger);
                leftStickX = MAX_MAGNITUDE(leftStickX, controller.mergedWithController.lastLeftStickX);
                leftStickY = MAX_MAGNITUDE(leftStickY, controller.mergedWithController.lastLeftStickY);
                rightStickX = MAX_MAGNITUDE(rightStickX, controller.mergedWithController.lastRightStickX);
                rightStickY = MAX_MAGNITUDE(rightStickY, controller.mergedWithController.lastRightStickY);
            }
            
            //NSLog(@"gamepadMask: %@", [self binaryRepresentationOfInteger:buttonFlags]); // we got the pressed OSC buttons here.
            
            // Player 0 is always present for OSC
            int inputResult = LiSendMultiControllerEvent(_multiController ? controller.streamPlayerIndex : 0,
                                                         [self getActiveGamepadMask],
                                                         buttonFlags, leftTrigger, rightTrigger,
                                                         leftStickX, leftStickY, rightStickX, rightStickY);
            CFTimeInterval now = CACurrentMediaTime();
            BOOL shouldRecordSendSummary = NO;
            NSUInteger inputPacketCount = 0;
            NSUInteger callbackCount = 0;
            NSUInteger processedSnapshotCount = 0;
            CFTimeInterval callbackCapturedAt = 0;
            @synchronized (controller) {
                inputPacketCount = ++controller.diagnosticInputPacketsSent;
                callbackCount = controller.diagnosticInputCallbacks;
                processedSnapshotCount = controller.diagnosticInputSnapshotsProcessed;
                callbackCapturedAt = controller.diagnosticCurrentSnapshotCapturedAt;
                shouldRecordSendSummary = inputResult != 0
                    ? (controller.diagnosticLastSendLogTime == 0 || now - controller.diagnosticLastSendLogTime >= 3.0)
                    : (controller.diagnosticLastSendLogTime == 0 || now - controller.diagnosticLastSendLogTime >= 2.0);
                if (shouldRecordSendSummary) controller.diagnosticLastSendLogTime = now;
            }
            if (shouldRecordSendSummary) {
                NSMutableDictionary<NSString *, id> *fields = [NSMutableDictionary dictionaryWithDictionary:diagnosticCommonControllerFields(controller)];
                fields[@"send_result"] = @(inputResult);
                fields[@"send_semantics"] = @"Zero is the client API success result; it is not a host acknowledgement.";
                fields[@"input_packet_count"] = @(inputPacketCount);
                fields[@"callback_count"] = @(callbackCount);
                fields[@"processed_snapshot_count"] = @(processedSnapshotCount);
                fields[@"active_port_mask"] = @([self getActiveGamepadMask]);
                fields[@"button_flags"] = [NSString stringWithFormat:@"0x%08x", buttonFlags];
                fields[@"triggers"] = @[@(leftTrigger), @(rightTrigger)];
                fields[@"left_stick"] = @[@(leftStickX), @(leftStickY)];
                fields[@"right_stick"] = @[@(rightStickX), @(rightStickY)];
                if (callbackCapturedAt > 0) fields[@"callback_to_send_ms"] = @((now - callbackCapturedAt) * 1000.0);
                [ControllerDiagnostics recordEvent:@"controller_input_send_summary" fields:fields];
            }
            if (inputResult != 0 && !controller.didLogControllerInputFailure) {
                Log(LOG_E, @"Could not send controller state for Sunshine P%d (error %d)",
                    controller.streamPlayerIndex + 1,
                    inputResult);
                controller.didLogControllerInputFailure = YES;
            }
            else if (inputResult == 0) {
                controller.didLogControllerInputFailure = NO;
            }
        }
        controller.diagnosticCurrentSnapshotCapturedAt = 0;
    }
    [_controllerStreamLock unlock];
    
    if (exitRequested) {
        // Invoke the delegate callback on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_delegate streamExitRequested];
        });
    }
}


- (NSString *)binaryRepresentationOfInteger:(int)number {
    NSMutableString *binaryString = [NSMutableString string];
    int numBits = sizeof(number) * 8;

    for (int i = numBits - 1; i >= 0; i--) {
        [binaryString appendString:((number >> i) & 1) ? @"1" : @"0"];
    }

    return binaryString;
}


+(BOOL) hasKeyboardOrMouse {
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        return GCMouse.mice.count > 0 || GCKeyboard.coalescedKeyboard != nil;
    }
    else {
        return NO;
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

-(void) unregisterControllerCallbacks:(GCController*) controller
{
    if (controller != NULL) {
        controller.controllerPausedHandler = NULL;
        
        if (@available(iOS 14.0, tvOS 14.0, *)) {
            for (GCControllerElement* element in controller.physicalInputProfile.allElements) {
                element.preferredSystemGestureState = GCSystemGestureStateEnabled;
            }
        }
        if (@available(iOS 16.0, tvOS 16.0, *)) {
            controller.physicalInputProfile.valueDidChangeHandler = NULL;
        }

        if (controller.extendedGamepad != NULL) {
            controller.extendedGamepad.valueChangedHandler = NULL;
        }
        if (@available(iOS 14.0, tvOS 14.0, *)) {
            // Do not leave a completed stream's private queue attached to a device.
            controller.handlerQueue = dispatch_get_main_queue();
        }
    }
}

-(void) initializeControllerHaptics:(VoidController*) controller
{
    controller.lowFreqMotor = [HapticContext createContextForLowFreqMotor:controller.gamepad];
    controller.highFreqMotor = [HapticContext createContextForHighFreqMotor:controller.gamepad];
    controller.leftTriggerMotor = [HapticContext createContextForLeftTrigger:controller.gamepad];
    controller.rightTriggerMotor = [HapticContext createContextForRightTrigger:controller.gamepad];
}

-(void) cleanupControllerHaptics:(VoidController*) controller
{
    if (@available(iOS 14.5, tvOS 14.5, *)) {
        if ([controller.gamepad.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
            GCDualSenseGamepad* dualSense = (GCDualSenseGamepad*)controller.gamepad.extendedGamepad;
            [dualSense.leftTrigger setModeOff];
            [dualSense.rightTrigger setModeOff];
        }
    }

    [controller.lowFreqMotor cleanup];
    [controller.highFreqMotor cleanup];
    [controller.leftTriggerMotor cleanup];
    [controller.rightTriggerMotor cleanup];
}

-(void) cleanupControllerMotion:(VoidController*) controller
{
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        // Stop sensor sampling timers
        [controller.gyroTimer invalidate];
        [controller.accelTimer invalidate];
        
        // Disable motion sensors if they require manual activation
        if (controller.gamepad && controller.gamepad.motion && controller.gamepad.motion.sensorsRequireManualActivation) {
            controller.gamepad.motion.sensorsActive = NO;
        }
    }
}

-(void) initializeControllerBattery:(VoidController*) controller
{
    // Generic-profile input is processed on a private serial queue. NSTimer must
    // be scheduled on a thread with a running run loop, so move timer setup back
    // to main and discard it if the controller disconnected in the meantime.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_controllerStreamLock lock];
            BOOL isCurrentController = [self voidControllerForGamepadLocked:controller.gamepad] == controller;
            [self->_controllerStreamLock unlock];
            if (self->_isCleaningUp || !isCurrentController) {
                return;
            }
            [self initializeControllerBattery:controller];
        });
        return;
    }

    if (@available(iOS 14.0, tvOS 14.0, *)) {
        if (controller.gamepad.battery) {
            // Poll for updated battery status every 30 seconds
            controller.batteryTimer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) {
                if ((GCDeviceBatteryState)controller.lastBatteryState != controller.gamepad.battery.batteryState ||
                    controller.lastBatteryLevel != controller.gamepad.battery.batteryLevel) {
                    uint8_t batteryState;
                    
                    switch (controller.gamepad.battery.batteryState) {
                        case GCDeviceBatteryStateFull:
                            batteryState = LI_BATTERY_STATE_FULL;
                            break;
                        case GCDeviceBatteryStateCharging:
                            batteryState = LI_BATTERY_STATE_CHARGING;
                            break;
                        case GCDeviceBatteryStateDischarging:
                            batteryState = LI_BATTERY_STATE_DISCHARGING;
                            break;
                        case GCDeviceBatteryStateUnknown:
                        default:
                            batteryState = LI_BATTERY_STATE_UNKNOWN;
                            break;
                    }
                    
            LiSendControllerBatteryEvent(controller.streamPlayerIndex, batteryState, (uint8_t)(controller.gamepad.battery.batteryLevel * 100));
                    
                    controller.lastBatteryState = (ControllerDeviceBatteryState)controller.gamepad.battery.batteryState;
                    controller.lastBatteryLevel = controller.gamepad.battery.batteryLevel;
                }
            }];
            
            // Fire the timer immediately to send the initial battery state
            [controller.batteryTimer fire];
        }
    }
}

-(void) cleanupControllerBattery:(VoidController*) controller
{
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        [controller.batteryTimer invalidate];
    }
}

// Callers must hold _controllerStreamLock so arrival and input packets stay ordered.
-(BOOL) reportControllerArrivalLocked:(VoidController*) voidController
{
    // Only report arrival once
    if (voidController.reportedArrival) {
        return YES;
    }

    if (voidController.waitsForInputBeforeArrival) {
        @synchronized (voidController) {
            if (!voidController.hasReceivedInput) {
                if (!voidController.didLogArrivalDeferred) {
                    voidController.didLogArrivalDeferred = YES;
                    [ControllerDiagnostics recordEvent:@"controller_arrival_deferred" fields:diagnosticCommonControllerFields(voidController)];
                }
                return NO;
            }
        }

        // Slot order follows first button press, not GameController's device
        // enumeration order. Empty adapter ports never reserve a host slot.
        if (![self assignStreamPlayerIndexLocked:voidController]) return NO;
        _controllerNumbers |= (1 << voidController.streamPlayerIndex);

        if (voidController.streamPlayerIndex == 0) {
            voidController.mergedWithController = _oscController;
            _oscController.mergedWithController = voidController;
            // Streaming navigation follows the controller that claimed P1.
            [ControllerUtil setStreamingPrimaryController:voidController.gamepad];
        }
        else {
            voidController.mergedWithController = nil;
            if (_oscController.mergedWithController == voidController) {
                _oscController.mergedWithController = nil;
            }
        }
    }
    
    /*
    for(OnScreenWidgetView* widget in OnScreenWidgetView.mapping.allValues) {
        if(widget.isFolder && widget.parentSequence<0 && widget.autoDockIdleDuration>0) {
            [widget restartAutoDockCountdown];
        }
    }
     */
    
    uint8_t type = LI_CTYPE_UNKNOWN;
    uint16_t capabilities = 0;
    uint32_t supportedButtonFlags = 0;
    
    GCController *controller = voidController.gamepad;
    if (controller) {
        // This is a physical controller with a corresponding GCController object
        
        [_delegate controllerArrivalWithPlayerIndex:voidController.streamPlayerIndex];
        
        // Start is always present
        supportedButtonFlags |= PLAY_FLAG;
        
        if (@available(iOS 16.0, tvOS 16.0, *)) {
            if (controller.extendedGamepad == nil) {
                GCPhysicalInputProfile *profile = controller.physicalInputProfile;
                NSDictionary<NSString *, GCControllerButtonInput *> *buttons = profile.buttons;

                if (profile.dpads[GCInputDirectionPad] != nil) {
                    supportedButtonFlags |= UP_FLAG | DOWN_FLAG | LEFT_FLAG | RIGHT_FLAG;
                }
                if (buttons[GCInputLeftShoulder] != nil) supportedButtonFlags |= LB_FLAG;
                if (buttons[GCInputRightShoulder] != nil) supportedButtonFlags |= RB_FLAG;
                if (buttons[GCInputButtonOptions] != nil) supportedButtonFlags |= BACK_FLAG;
                if (buttons[GCInputButtonHome] != nil) supportedButtonFlags |= SPECIAL_FLAG;
                if (buttons[GCInputButtonA] != nil) supportedButtonFlags |= A_FLAG;
                if (buttons[GCInputButtonB] != nil) supportedButtonFlags |= B_FLAG;
                if (buttons[GCInputButtonX] != nil) supportedButtonFlags |= X_FLAG;
                if (buttons[GCInputButtonY] != nil) supportedButtonFlags |= Y_FLAG;
                if (buttons[GCInputLeftThumbstickButton] != nil) supportedButtonFlags |= LS_CLK_FLAG;
                if (buttons[GCInputRightThumbstickButton] != nil) supportedButtonFlags |= RS_CLK_FLAG;
                if (buttons[GCInputXboxPaddleOne] != nil) supportedButtonFlags |= PADDLE1_FLAG;
                if (buttons[GCInputXboxPaddleTwo] != nil) supportedButtonFlags |= PADDLE2_FLAG;
                if (buttons[GCInputXboxPaddleThree] != nil) supportedButtonFlags |= PADDLE3_FLAG;
                if (buttons[GCInputXboxPaddleFour] != nil) supportedButtonFlags |= PADDLE4_FLAG;
                if (buttons[GCInputDualShockTouchpadButton] != nil) supportedButtonFlags |= TOUCHPAD_FLAG;
                if (profile.dpads[GCInputDualShockTouchpadOne] != nil) capabilities |= LI_CCAP_TOUCHPAD;
                if (buttons[GCInputLeftTrigger].isAnalog || buttons[GCInputRightTrigger].isAnalog) {
                    capabilities |= LI_CCAP_ANALOG_TRIGGERS;
                }
                if (@available(iOS 15.0, tvOS 15.0, *)) {
                    if (buttons[GCInputButtonShare] != nil) supportedButtonFlags |= MISC_FLAG;
                }

                uint8_t configuredType = _streamConfig.emulatedControllerType;
                if (configuredType == ControllerEmulationXboxAndPs) {
                    type = voidController.streamPlayerIndex == 0 ? LI_CTYPE_PS : LI_CTYPE_XBOX;
                }
                else if (configuredType == ControllerEmulationPsEnhancedHaptic) {
                    type = LI_CTYPE_PS;
                }
                else if (configuredType == LI_CTYPE_UNKNOWN) {
                    type = LI_CTYPE_XBOX;
                }
                else {
                    type = configuredType;
                }
            }
        }

        // Detect buttons present in the GCExtendedGamepad profile
        if (controller.extendedGamepad.dpad) {
            supportedButtonFlags |= UP_FLAG | DOWN_FLAG | LEFT_FLAG | RIGHT_FLAG;
        }
        if (controller.extendedGamepad.leftShoulder) {
            supportedButtonFlags |= LB_FLAG;
        }
        if (controller.extendedGamepad.rightShoulder) {
            supportedButtonFlags |= RB_FLAG;
        }
        if (@available(iOS 13.0, tvOS 13.0, *)) {
            if (controller.extendedGamepad.buttonOptions) {
                supportedButtonFlags |= BACK_FLAG;
            }
        }
        if (@available(iOS 14.0, tvOS 14.0, *)) {
            if (controller.extendedGamepad.buttonHome) {
                supportedButtonFlags |= SPECIAL_FLAG;
            }
        }
        if (controller.extendedGamepad.buttonA) {
            supportedButtonFlags |= A_FLAG;
        }
        if (controller.extendedGamepad.buttonB) {
            supportedButtonFlags |= B_FLAG;
        }
        if (controller.extendedGamepad.buttonX) {
            supportedButtonFlags |= X_FLAG;
        }
        if (controller.extendedGamepad.buttonY) {
            supportedButtonFlags |= Y_FLAG;
        }
        if (@available(iOS 12.1, tvOS 12.1, *)) {
            if (controller.extendedGamepad.leftThumbstickButton) {
                supportedButtonFlags |= LS_CLK_FLAG;
            }
            if (controller.extendedGamepad.rightThumbstickButton) {
                supportedButtonFlags |= RS_CLK_FLAG;
            }
        }
        
        if (@available(iOS 14.0, tvOS 14.0, *)) {
            // Xbox One/Series controller
            if (controller.physicalInputProfile.buttons[GCInputXboxPaddleOne]) {
                supportedButtonFlags |= PADDLE1_FLAG;
            }
            if (controller.physicalInputProfile.buttons[GCInputXboxPaddleTwo]) {
                supportedButtonFlags |= PADDLE2_FLAG;
            }
            if (controller.physicalInputProfile.buttons[GCInputXboxPaddleThree]) {
                supportedButtonFlags |= PADDLE3_FLAG;
            }
            if (controller.physicalInputProfile.buttons[GCInputXboxPaddleFour]) {
                supportedButtonFlags |= PADDLE4_FLAG;
            }
            if (@available(iOS 15.0, tvOS 15.0, *)) {
                if (controller.physicalInputProfile.buttons[GCInputButtonShare]) {
                    supportedButtonFlags |= MISC_FLAG;
                }
            }
            
            // DualShock/DualSense controller
            if (controller.physicalInputProfile.buttons[GCInputDualShockTouchpadButton]) {
                supportedButtonFlags |= TOUCHPAD_FLAG;
            }
            if (controller.physicalInputProfile.dpads[GCInputDualShockTouchpadOne]) {
                capabilities |= LI_CCAP_TOUCHPAD;
            }
            
            // LI_CTYPE_UNKNOWN for option "Both"
            if(voidController.streamPlayerIndex == 0){
                type = _streamConfig.emulatedControllerType == ControllerEmulationXboxAndPs ? LI_CTYPE_PS : _streamConfig.emulatedControllerType;
                if(type == ControllerEmulationPsEnhancedHaptic) type = ControllerEmulationPs;
            }
            
            if(voidController.streamPlayerIndex == 1 && _streamConfig.emulatedControllerType == LI_CTYPE_UNKNOWN){
                type = LI_CTYPE_XBOX;
            }
            
            if(voidController.streamPlayerIndex >= 1 && _streamConfig.emulatedControllerType != LI_CTYPE_UNKNOWN){
                if ([controller.extendedGamepad isKindOfClass:[GCXboxGamepad class]]) {
                    type = LI_CTYPE_XBOX;
                }
                if ([controller.extendedGamepad isKindOfClass:[GCDualShockGamepad class]]) {
                    type = LI_CTYPE_PS;
                }
                
                if (@available(iOS 14.5, tvOS 14.5, *)) {
                    if ([controller.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
                        type = LI_CTYPE_PS;
                        capabilities |= LI_CCAP_DS5_HAPTICS_PCM;
                    }
                }
            }
                        
#if !TARGET_OS_TV
            if (voidController.hardware == ControllerHardwareRazerKishi) {
                capabilities |= LI_CCAP_RUMBLE;
            }
#endif
            // Detect supported haptics localities
            if (controller.haptics) {
                if ([controller.haptics.supportedLocalities containsObject:GCHapticsLocalityHandles]) {
                    capabilities |= LI_CCAP_RUMBLE;
                }
                if ([controller.haptics.supportedLocalities containsObject:GCHapticsLocalityTriggers]) {
                    capabilities |= LI_CCAP_TRIGGER_RUMBLE;
                }
            }
            
            // Detect supported motion sensors
            if (controller.motion) {
                if (controller.motion.hasGravityAndUserAcceleration) {
                    capabilities |= LI_CCAP_ACCEL;
                }
                if (controller.motion.hasRotationRate) {
                    capabilities |= LI_CCAP_GYRO;
                }
            }

            
            
            // Detect RGB LED support
            if (controller.light) {
                capabilities |= LI_CCAP_RGB_LED;
            }
            
            // Detect battery support
            if (controller.battery) {
                capabilities |= LI_CCAP_BATTERY_STATE;
            }
            
            bool controllerLacksGyro = (capabilities & LI_CCAP_GYRO) == 0;
            if((_streamConfig.emulatedControllerType == ControllerEmulationPs || _streamConfig.emulatedControllerType == ControllerEmulationPsEnhancedHaptic)
               && (_gyroMode == AlwaysDevice || (_gyroMode == GyroModeAuto && controllerLacksGyro)))
            {
                type = LI_CTYPE_PS;
                capabilities |= LI_CCAP_GYRO | LI_CCAP_ACCEL;
            }
        }

        // Generic profiles do not identify themselves as Xbox or PlayStation.
        // Honor the selected emulation type after the extended-profile logic above.
        if (controller.extendedGamepad == nil) {
            uint8_t configuredType = _streamConfig.emulatedControllerType;
            if (configuredType == ControllerEmulationXboxAndPs) {
                type = voidController.streamPlayerIndex == 0 ? LI_CTYPE_PS : LI_CTYPE_XBOX;
            }
            else if (configuredType == ControllerEmulationPsEnhancedHaptic) {
                type = LI_CTYPE_PS;
            }
            else {
                type = configuredType == LI_CTYPE_UNKNOWN ? LI_CTYPE_XBOX : configuredType;
            }
        }
    }
    else {
        // This is a virtual controller corresponding to our OSC
        // set osc to PS to utilize built-in gyro when "both" is selected
        type = _streamConfig.emulatedControllerType == LI_CTYPE_UNKNOWN ? LI_CTYPE_PS : _streamConfig.emulatedControllerType;
        if(type == ControllerEmulationPsEnhancedHaptic) type = LI_CTYPE_PS;
        /*
        if (_streamConfig.gyroMode != GyroModeOff) {
            type = LI_CTYPE_PS;
            capabilities = LI_CCAP_GYRO | LI_CCAP_ACCEL;
        }
        else {
            type = LI_CTYPE_XBOX;
            capabilities = 0;
        }
         */


        // Set the standard supported buttons for the virtual controller.
        supportedButtonFlags =
            PLAY_FLAG | BACK_FLAG | UP_FLAG | DOWN_FLAG | LEFT_FLAG | RIGHT_FLAG |
            LB_FLAG | RB_FLAG | LS_CLK_FLAG | RS_CLK_FLAG | A_FLAG | B_FLAG | X_FLAG | Y_FLAG;
    }

    // Report the new controller to the host
    // NB: This will fail if the connection hasn't been fully established yet
    // and we will try again later.
    int arrivalResult = LiSendControllerArrivalEvent(voidController.streamPlayerIndex,
                                                      [self getActiveGamepadMask],
                                                      type,
                                                      supportedButtonFlags,
                                                      capabilities);
    CFTimeInterval now = CACurrentMediaTime();
    NSUInteger arrivalAttempts;
    BOOL shouldRecordArrival;
    @synchronized (voidController) {
        arrivalAttempts = ++voidController.diagnosticArrivalAttempts;
        shouldRecordArrival = arrivalResult == 0 || voidController.diagnosticLastArrivalLogTime == 0 ||
            now - voidController.diagnosticLastArrivalLogTime >= 3.0;
        if (shouldRecordArrival) voidController.diagnosticLastArrivalLogTime = now;
    }
    if (shouldRecordArrival) {
        NSMutableDictionary<NSString *, id> *fields = [NSMutableDictionary dictionaryWithDictionary:diagnosticCommonControllerFields(voidController)];
        fields[@"send_result"] = @(arrivalResult);
        fields[@"attempt"] = @(arrivalAttempts);
        fields[@"active_port_mask"] = @([self getActiveGamepadMask]);
        fields[@"supported_button_flags"] = [NSString stringWithFormat:@"0x%08x", supportedButtonFlags];
        fields[@"controller_type"] = @(type);
        fields[@"capabilities"] = @(capabilities);
        fields[@"has_received_input"] = @(voidController.hasReceivedInput);
        fields[@"send_semantics"] = @"Zero is the client API success result; it is not a host acknowledgement.";
        [ControllerDiagnostics recordEvent:@"controller_arrival_send" fields:fields];
    }
    if (arrivalResult != 0) {
        if (!voidController.didLogControllerArrivalFailure) {
            Log(LOG_E, @"Could not announce %@ as Sunshine P%d (error %d); will retry on the next input",
                voidController.gamepad.vendorName ?: @"controller",
                voidController.streamPlayerIndex + 1,
                arrivalResult);
            voidController.didLogControllerArrivalFailure = YES;
        }
        if (voidController.waitsForInputBeforeArrival) {
            _controllerNumbers &= ~(1 << voidController.streamPlayerIndex);
        }
        return NO;
    }
    
    // Begin polling for battery status
    // Remember that we've reported arrival already
    voidController.reportedArrival = YES;
    voidController.didLogControllerArrivalFailure = NO;
    if (voidController.waitsForInputBeforeArrival) {
        _reservedControllerNumbers &= ~(1 << voidController.streamPlayerIndex);
    }
    Log(LOG_I, @"Assigned %@ to Sunshine P%d on first button press",
        voidController.gamepad.vendorName ?: @"controller",
        voidController.streamPlayerIndex + 1);
    [self initializeControllerBattery:voidController];
    [self updateTimerStateForController:voidController];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_delegate gamepadPresenceChanged];
    });
    return YES;
}

-(void) handleControllerTouchpad:(VoidController*)controller touch:(GCControllerDirectionPad*)touch index:(int)index
{
    [self handleControllerTouchpad:controller
                                  x:touch.xAxis.value
                                  y:touch.yAxis.value
                            active:(touch.xAxis.value != 0 || touch.yAxis.value != 0)
                             index:index];
}

-(void) handleControllerTouchpad:(VoidController*)controller x:(float)x y:(float)y active:(BOOL)isActive index:(int)index
{
    if (!controller.reportedArrival || controller.streamPlayerIndex < 0) return;
    controller_touch_context_t context = index == 0 ? controller.primaryTouch : controller.secondaryTouch;
    
    // This magic is courtesy of SDL
    float normalizedX = (1.0f + x) * 0.5f;
    float normalizedY = 1.0f - (1.0f + y) * 0.5f;
    
    // If we went from a touch to no touch, generate a touch up event
    if (context.isActive && !isActive) {
        LiSendControllerTouchEvent(controller.streamPlayerIndex, LI_TOUCH_EVENT_UP, index, normalizedX, normalizedY, 1.0f);
    }
    else if (isActive) {
        // If we went from no touch to a touch, generate a touch down event
        if (!context.isActive) {
        LiSendControllerTouchEvent(controller.streamPlayerIndex, LI_TOUCH_EVENT_DOWN, index, normalizedX, normalizedY, 1.0f);
        }
        else if (context.lastX != x || context.lastY != y) {
            // Otherwise it's just a move
        LiSendControllerTouchEvent(controller.streamPlayerIndex, LI_TOUCH_EVENT_MOVE, index, normalizedX, normalizedY, 1.0f);
        }
    }
    
    // We have to assign the whole struct because this is a property rather than a standard
    // field that we could modify through a pointer.
    if (index == 0) {
        controller.primaryTouch = (controller_touch_context_t) { x, y, isActive };
    }
    else {
        controller.secondaryTouch = (controller_touch_context_t) { x, y, isActive };
    }
}

double rc_expo(double x, double expo) {
    if (x == 0.0) return 0.0;

    double ax = fabs(x);
    double y = pow(ax, expo);

    return x > 0 ? y : -y;
}


- (bool)useMotionHandler{
    return tempSettings.gyroMode.intValue == GyroModeOff
    || tempSettings.gyroMode.intValue == AlwaysDevice;
}

- (void)switchMotionControlOnOffByControllerButton{
    self->_gyroEnabledFlag = self->_gyroEnabledFlag && self->_controllerGyroSwitchEnabled;
    if([self useMotionHandler]){
        if(self->_gyroEnabledFlag) [self->motionHandler startMotionControlByControllerButton];
        else [self->motionHandler stopMotionUpdateWithInterruptNoneGyroInput:false];
    }
    self->_gyroEnabledFlag = self->_gyroEnabledFlag || !self->_controllerGyroSwitchEnabled;
}

- (void)updateGyroSwitchForController:(VoidController*)controller buttonFlag:(int)buttonFlag pressed:(BOOL)pressed {
    NSInteger playerIndex = controller.playerIndex;
    if (playerIndex < 0 || playerIndex >= 32) return;

    uint32_t playerMask = (uint32_t)1 << playerIndex;
    @synchronized (self) {
        if (self->_isCleaningUp) return;

        BOOL isToggleButton = buttonFlag == self->_controllerGyroSwitchToggle;
        BOOL isHoldButton = buttonFlag == self->_controllerGyroSwitchHold;
        if (!self->_controllerGyroSwitchEnabled || (!isToggleButton && !isHoldButton)) return;

        BOOL wasGyroEnabled = self->_gyroEnabledFlag;
        if (isToggleButton) {
            BOOL wasPressed = (self->_controllerGyroSwitchTogglePressedMask & playerMask) != 0;
            if (pressed && !wasPressed) {
                self->_controllerGyroSwitchTogglePressedMask |= playerMask;
                self->_gyroToggleEnabled = !self->_gyroToggleEnabled;
            }
            else if (!pressed && wasPressed) {
                self->_controllerGyroSwitchTogglePressedMask &= ~playerMask;
            }
        }

        if (isHoldButton) {
            BOOL wasPressed = (self->_controllerGyroSwitchHoldPressedMask & playerMask) != 0;
            if (pressed && !wasPressed) {
                self->_controllerGyroSwitchHoldPressedMask |= playerMask;
            }
            else if (!pressed && wasPressed) {
                self->_controllerGyroSwitchHoldPressedMask &= ~playerMask;
            }
        }

        BOOL holdIsActive = self->_controllerGyroSwitchHoldPressedMask != 0;
        BOOL toggleButtonConfigured = self->_controllerGyroSwitchToggle != ControllerElementNull;
        self->_gyroEnabledFlag = holdIsActive
            ? !self->_reverseHoldButton
            : (toggleButtonConfigured ? self->_gyroToggleEnabled : self->_reverseHoldButton);

        if (self->_gyroEnabledFlag != wasGyroEnabled) {
            BOOL requestedGyroEnabled = self->_gyroEnabledFlag;
            // Generic-profile input is processed on a worker queue, while the
            // motion callback and its stick-mixing state run on the main queue.
            dispatch_async(dispatch_get_main_queue(), ^{
                @synchronized (self) {
                    // A fast press/release can queue both transitions before
                    // main processes either one. Ignore stale transitions so a
                    // short press still leaves motion control in the final state.
                    if (self->_isCleaningUp || self->_gyroEnabledFlag != requestedGyroEnabled) return;
                    [self switchMotionControlOnOffByControllerButton];
                }
            });
        }
    }
}

- (void)releaseControllerTouchpadContacts:(VoidController*)controller {
    for (int index = 0; index < 2; index++) {
        controller_touch_context_t context = index == 0 ? controller.primaryTouch : controller.secondaryTouch;
        if (context.isActive) {
            float normalizedX = (1.0f + context.lastX) * 0.5f;
            float normalizedY = 1.0f - (1.0f + context.lastY) * 0.5f;
            LiSendControllerTouchEvent((uint8_t)controller.streamPlayerIndex, LI_TOUCH_EVENT_UP,
                                       (uint32_t)index, normalizedX, normalizedY, 1.0f);
        }

        controller_touch_context_t emptyContext = {0};
        if (index == 0) {
            controller.primaryTouch = emptyContext;
        }
        else {
            controller.secondaryTouch = emptyContext;
        }
    }
}

- (void)resetGyroSwitchForPlayerIndex:(NSInteger)playerIndex {
    if (playerIndex < 0 || playerIndex >= 32) return;

    uint32_t playerMask = (uint32_t)1 << playerIndex;
    @synchronized (self) {
        BOOL wasGyroEnabled = self->_gyroEnabledFlag;
        BOOL hadSwitchButtonPressed =
            (self->_controllerGyroSwitchTogglePressedMask & playerMask) != 0 ||
            (self->_controllerGyroSwitchHoldPressedMask & playerMask) != 0;
        self->_controllerGyroSwitchTogglePressedMask &= ~playerMask;
        self->_controllerGyroSwitchHoldPressedMask &= ~playerMask;
        if (hadSwitchButtonPressed) {
            BOOL holdIsActive = self->_controllerGyroSwitchHoldPressedMask != 0;
            BOOL toggleButtonConfigured = self->_controllerGyroSwitchToggle != ControllerElementNull;
            self->_gyroEnabledFlag = holdIsActive
                ? !self->_reverseHoldButton
                : (toggleButtonConfigured ? self->_gyroToggleEnabled : self->_reverseHoldButton);
        }
        if (self->_gyroEnabledFlag != wasGyroEnabled) {
            [self switchMotionControlOnOffByControllerButton];
        }
    }
}

- (void)sendNavigationButtonPress {
    if(!ControllerUtil.primaryGCController) return;
    if(@available(iOS 13.0, *)) if(ControllerNavigator.controllerMouseEnabled) return;
    [self->_controllerStreamLock lock];
    VoidController* voidController = [self voidControllerForGamepadLocked:ControllerUtil.primaryGCController];
    [self->_controllerStreamLock unlock];
    int radialMenuButton = ControllerElementNull;
    if (@available(iOS 13.0, *)) radialMenuButton = ControllerNavigator.radialMenuButton;
    [self setButtonFlag:voidController flags:(int)radialMenuButton];
    [self updateFinished:voidController];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.03*NSEC_PER_SEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self clearButtonFlag:voidController flags:radialMenuButton];
        [self updateFinished:voidController];
    });
}


- (void) listenToGCController:(GCController*) controller {
    /*
    if(self->_swapABXYButtons){
        switch (self->_controllerMouseLeftButton) {
            case ControllerElementA:
                self->_controllerMouseLeftButton = ControllerElementB;
                break;
            case ControllerElementB:
                self->_controllerMouseLeftButton = ControllerElementA;
                break;
            case ControllerElementX:
                self->_controllerMouseLeftButton = ControllerElementY;
                break;
            case ControllerElementY:
                self->_controllerMouseLeftButton = ControllerElementX;
                break;
            default:
                break;
        }
        switch (self->_controllerMouseRightButton) {
            case ControllerElementA:
                self->_controllerMouseRightButton = ControllerElementB;
                break;
            case ControllerElementB:
                self->_controllerMouseRightButton = ControllerElementA;
                break;
            case ControllerElementX:
                self->_controllerMouseRightButton = ControllerElementY;
                break;
            case ControllerElementY:
                self->_controllerMouseRightButton = ControllerElementX;
                break;
            default:
                break;
        }
    }
     */
    
    [ControllerUtil listenWithController:controller swapABXY:self->_swapABXYButtons handler:^(NSDictionary *elementDict, GCExtendedGamepad *gamepad, GCControllerElement *element) {
        VoidController *voidController = nil;
        NSUInteger orderGeneration = 0;
        [self->_controllerStreamLock lock];
        voidController = [self voidControllerForGamepadLocked:controller];
        [self->_controllerStreamLock unlock];
        if (voidController == nil) return;
        @synchronized (voidController) {
            if (!voidController.acceptsInput || voidController.gamepad != controller) return;
            orderGeneration = voidController.inputOrderGeneration;
        }

        // Snapshot GameController values before queueing, just like the generic
        // profile path. GameController can update these objects before a worker
        // reads them, so the worker only receives immutable scalar values.
        NSMutableDictionary<NSNumber *, NSNumber *> *capturedButtonStates = [NSMutableDictionary dictionary];
        for (NSNumber *elementFlagId in elementDict) {
            GCControllerElement *mappedElement = elementDict[elementFlagId];
            if ([mappedElement isKindOfClass:[GCControllerButtonInput class]]) {
                capturedButtonStates[elementFlagId] = @(((GCControllerButtonInput *)mappedElement).pressed);
            }
        }
        NSDictionary<NSNumber *, NSNumber *> *buttonStates = [capturedButtonStates copy];
        BOOL hasPressedButton = NO;
        for (NSNumber *elementFlagId in buttonStates) {
            if (!buttonStates[elementFlagId].boolValue) continue;
            int buttonFlag = elementFlagId.intValue;
            if (buttonFlag == ControllerElementLeftTrigger || buttonFlag == ControllerElementRightTrigger) continue;
            hasPressedButton = YES;
            break;
        }

        CGFloat leftX = gamepad.leftThumbstick.xAxis.value;
        CGFloat leftY = gamepad.leftThumbstick.yAxis.value;
        CGFloat rightX = gamepad.rightThumbstick.xAxis.value;
        CGFloat rightY = gamepad.rightThumbstick.yAxis.value;
        CGFloat leftTriggerValue = gamepad.leftTrigger.value;
        CGFloat rightTriggerValue = gamepad.rightTrigger.value;
        hasPressedButton = hasPressedButton ||
            leftTriggerValue > ControllerUtil.controllerTriggerDeadzone ||
            rightTriggerValue > ControllerUtil.controllerTriggerDeadzone;
        unsigned char leftTrigger = triggerValueToByte(leftTriggerValue);
        unsigned char rightTrigger = triggerValueToByte(rightTriggerValue);

        float primaryTouchX = 0;
        float primaryTouchY = 0;
        BOOL primaryTouchActive = NO;
        float secondaryTouchX = 0;
        float secondaryTouchY = 0;
        BOOL secondaryTouchActive = NO;
        if (@available(iOS 14.0, tvOS 14.0, *)) {
            GCControllerDirectionPad *primaryTouch = controller.physicalInputProfile.dpads[GCInputDualShockTouchpadOne];
            if (primaryTouch != nil) {
                primaryTouchX = primaryTouch.xAxis.value;
                primaryTouchY = primaryTouch.yAxis.value;
                primaryTouchActive = primaryTouchX != 0 || primaryTouchY != 0;
            }
            GCControllerDirectionPad *secondaryTouch = controller.physicalInputProfile.dpads[GCInputDualShockTouchpadTwo];
            if (secondaryTouch != nil) {
                secondaryTouchX = secondaryTouch.xAxis.value;
                secondaryTouchY = secondaryTouch.yAxis.value;
                secondaryTouchActive = secondaryTouchX != 0 || secondaryTouchY != 0;
            }
        }

        BOOL hasMeaningfulInput = hasPressedButton ||
            fabs(leftX) >= 0.15 || fabs(leftY) >= 0.15 ||
            fabs(rightX) >= 0.15 || fabs(rightY) >= 0.15 ||
            primaryTouchActive || secondaryTouchActive;

        CFTimeInterval callbackCapturedAt = CACurrentMediaTime();
        GCPhysicalInputProfile *physicalProfile = controller.physicalInputProfile;
        recordControllerInputCallback(voidController, @"extended", physicalProfile,
                                      element, @"",
                                      buttonStates, elementDict, hasMeaningfulInput,
                                      leftX, leftY, rightX, rightY,
                                      leftTriggerValue, rightTriggerValue);

        // Streaming radial-menu input is always logical Start. Do not read the
        // app-primary setting here: it can still be RT while P1 is switching
        // from the pre-stream controller to a generic adapter endpoint.
        int radialMenuButton = ControllerElementStart;
        BOOL controllerNavigatorEnabled = NO;
        if (@available(iOS 13.0, tvOS 13.0, *)) {
            controllerNavigatorEnabled = ControllerNavigator.enabled;
        }
        dispatchControllerInputWork(self->_controllerInputQueue, ^{
            recordControllerInputWorkerDequeued(voidController, callbackCapturedAt);
            BOOL newlyClaimedSlot = NO;
            @synchronized (voidController) {
                if (!voidController.acceptsInput || voidController.gamepad != controller ||
                    voidController.inputOrderGeneration != orderGeneration) return;
                if (voidController.requiresButtonReleaseAfterOrderReset) {
                    if (!hasMeaningfulInput) voidController.requiresButtonReleaseAfterOrderReset = NO;
                }
                else if (!voidController.hasReceivedInput && hasMeaningfulInput) {
                    voidController.hasReceivedInput = YES;
                    newlyClaimedSlot = YES;
                }
            }

            // Assign the host port before processing this snapshot. That lets
            // the very first Start press be handled as P1's radial-menu action.
            if (newlyClaimedSlot) {
                Log(LOG_I, @"Controller %@ received its first input; requesting a Sunshine port",
                    controller.vendorName ?: @"controller");
                [ControllerDiagnostics recordEvent:@"controller_first_input_claimed" fields:diagnosticCommonControllerFields(voidController)];
                [self->_controllerStreamLock lock];
                [self reportControllerArrivalLocked:voidController];
                [self->_controllerStreamLock unlock];
            }

            for (NSNumber *elementFlagId in buttonStates) {
                BOOL pressed = buttonStates[elementFlagId].boolValue;
                int buttonFlag = elementFlagId.intValue;
                BOOL isTrigger = buttonFlag == ControllerElementLeftTrigger || buttonFlag == ControllerElementRightTrigger;
                if (isTrigger) {
                    CGFloat triggerValue = buttonFlag == ControllerElementLeftTrigger ? leftTriggerValue : rightTriggerValue;
                    @synchronized (voidController) {
                        BOOL wasPressed = buttonFlag == ControllerElementLeftTrigger
                            ? voidController.leftTriggerDigitallyPressed
                            : voidController.rightTriggerDigitallyPressed;
                        pressed = triggerValueIsDigitallyPressed(triggerValue, wasPressed);
                        if (buttonFlag == ControllerElementLeftTrigger) {
                            voidController.leftTriggerDigitallyPressed = pressed;
                        } else {
                            voidController.rightTriggerDigitallyPressed = pressed;
                        }
                    }
                }
                [self updateGyroSwitchForController:voidController buttonFlag:buttonFlag pressed:pressed];
                BOOL isStreamPrimary = voidController.streamPlayerIndex == 0;
                if (controllerNavigatorEnabled && isStreamPrimary && buttonFlag == radialMenuButton) {
                    BOOL changed = NO;
                    @synchronized (voidController) {
                        if (voidController.radialMenuButtonPressed != pressed) {
                            voidController.radialMenuButtonPressed = pressed;
                            changed = YES;
                        }
                    }
                    if (changed) {
                        NSString *radialPhysicalElementName = @"";
                        if (element == elementDict[@(radialMenuButton)]) {
                            radialPhysicalElementName = diagnosticPhysicalNameForElement(physicalProfile, element);
                        }
                        recordStreamingRadialButtonSource(voidController, buttonFlag, pressed, radialPhysicalElementName);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self->_controllerStreamLock lock];
                            BOOL stillPrimary = [self voidControllerForStreamPlayerIndexLocked:0] == voidController;
                            [self->_controllerStreamLock unlock];
                            if (stillPrimary) [ControllerNavigator handleStreamingRadialMenuButton:pressed];
                        });
                    }
                    // Start opens the radial menu, but it is also a real gamepad
                    // button and must remain visible to the streaming host.
                    UPDATE_BUTTON_FLAG(voidController, buttonFlag, pressed);
                }
                else if (!isTrigger) {
                    UPDATE_BUTTON_FLAG(voidController, buttonFlag, pressed);
                }
            }

            CGVector leftOffset = [ControllerUtil compensatedWithOffsetVector:CGVectorMake(leftX * self->stickMaxOffset,
                                                                                             leftY * self->stickMaxOffset)
                                                                     minOffset:self->_leftStickMinOffset
                                                                      circulate:false];
            CGVector rightOffset = [ControllerUtil compensatedWithOffsetVector:CGVectorMake(rightX * self->stickMaxOffset,
                                                                                              rightY * self->stickMaxOffset)
                                                                       minOffset:self->_rightStickMinOffset
                                                                        circulate:false];
            short leftStickX = (short)leftOffset.dx;
            short leftStickY = (short)leftOffset.dy;
            short rightStickX = (short)rightOffset.dx;
            short rightStickY = (short)rightOffset.dy;

            // Keep physical axes on their own controller. updateFinished merges
            // that state with OSC for P1; redirecting samples to OSC here can
            // leave a pre-assignment physical value stuck in the merged state.
            if (voidController.streamPlayerIndex == 0
                && [self useMotionHandler]
                && self->motionHandler.motionControlStarted
                && self->oscProfile.mapGyroTo == mapGyroToControllerStick
                && self->oscProfile.yawPitchToRightStick
                && self->_gyroEnabledFlag) {
                [self->motionHandler mixPhysicalRightStickAndGyroInputWithX:rightStickX y:rightStickY];
            }
            else {
                [self updateRightStick:voidController
                                     x:rightStickX
                                     y:rightStickY];
            }

            if (voidController.streamPlayerIndex == 0
                && [self useMotionHandler]
                && self->motionHandler.motionControlStarted
                && self->oscProfile.mapGyroTo == mapGyroToControllerStick
                && self->oscProfile.rollToLeftStick
                && self->_gyroEnabledFlag) {
                [self->motionHandler mixPhysicalLeftStickAndGyroInputWithX:leftStickX y:leftStickY];
            }
            else {
                [self updateLeftStick:voidController
                                    x:leftStickX
                                    y:leftStickY];
            }

            [self updateTriggers:voidController left:leftTrigger right:rightTrigger];
            [self updateFinished:voidController];
            [self handleControllerTouchpad:voidController x:primaryTouchX y:primaryTouchY active:primaryTouchActive index:0];
            [self handleControllerTouchpad:voidController x:secondaryTouchX y:secondaryTouchY active:secondaryTouchActive index:1];
        });
    }];
}

- (void) listenToGenericGCController:(GCController*) controller API_AVAILABLE(ios(16.0), tvos(16.0)) {
     [ControllerUtil listenPhysicalProfileWithController:controller
                                             swapABXY:self->_swapABXYButtons
                                          handlerQueue:self->_controllerInputQueue
                                               handler:^(NSDictionary *elementDict, GCPhysicalInputProfile *profile, GCControllerElement *changedElement, NSString *changedElementName) {
        NSUInteger orderGeneration = 0;
        [self->_controllerStreamLock lock];
        VoidController *voidController = [self voidControllerForGamepadLocked:controller];
        [self->_controllerStreamLock unlock];
        if (voidController == nil) return;
        @synchronized (voidController) {
            if (!voidController.acceptsInput || voidController.gamepad != controller) return;
            orderGeneration = voidController.inputOrderGeneration;
        }

        // Game Controller callbacks run on the controller's handler queue. Copy
        // all values here so the input worker never reads live GameController
        // elements or profiles from a different queue.
        NSMutableDictionary<NSNumber *, NSNumber *> *capturedButtonStates = [NSMutableDictionary dictionary];
        BOOL hasPressedButton = NO;
        for (NSNumber *elementFlagId in elementDict) {
            GCControllerElement *mappedElement = elementDict[elementFlagId];
            if (![mappedElement isKindOfClass:[GCControllerButtonInput class]]) continue;

            BOOL pressed = ((GCControllerButtonInput *)mappedElement).pressed;
            capturedButtonStates[elementFlagId] = @(pressed);
            int buttonFlag = elementFlagId.intValue;
            if (pressed && buttonFlag != ControllerElementLeftTrigger && buttonFlag != ControllerElementRightTrigger) {
                hasPressedButton = YES;
            }
        }

        GCControllerDirectionPad *leftStick = profile.dpads[GCInputLeftThumbstick];
        GCControllerDirectionPad *rightStick = profile.dpads[GCInputRightThumbstick];
        CGFloat leftX = leftStick ? leftStick.xAxis.value : 0;
        CGFloat leftY = leftStick ? leftStick.yAxis.value : 0;
        CGFloat rightX = rightStick ? rightStick.xAxis.value : 0;
        CGFloat rightY = rightStick ? rightStick.yAxis.value : 0;
        CGFloat leftTriggerValue = profile.buttons[GCInputLeftTrigger].value;
        CGFloat rightTriggerValue = profile.buttons[GCInputRightTrigger].value;
        hasPressedButton = hasPressedButton ||
            leftTriggerValue > ControllerUtil.controllerTriggerDeadzone ||
            rightTriggerValue > ControllerUtil.controllerTriggerDeadzone;
        unsigned char leftTrigger = triggerValueToByte(leftTriggerValue);
        unsigned char rightTrigger = triggerValueToByte(rightTriggerValue);

        float primaryTouchX = 0;
        float primaryTouchY = 0;
        BOOL primaryTouchActive = NO;
        GCControllerTouchpad *primaryTouchpad = profile.touchpads[GCInputDualShockTouchpadOne];
        if (primaryTouchpad != nil) {
            GCControllerDirectionPad *touchSurface = primaryTouchpad.touchSurface;
            primaryTouchX = touchSurface.xAxis.value;
            primaryTouchY = touchSurface.yAxis.value;
            primaryTouchActive = primaryTouchpad.touchState != GCTouchStateUp;
        }
        else if (profile.dpads[GCInputDualShockTouchpadOne] != nil) {
            GCControllerDirectionPad *touch = profile.dpads[GCInputDualShockTouchpadOne];
            primaryTouchX = touch.xAxis.value;
            primaryTouchY = touch.yAxis.value;
            primaryTouchActive = primaryTouchX != 0 || primaryTouchY != 0;
        }

        float secondaryTouchX = 0;
        float secondaryTouchY = 0;
        BOOL secondaryTouchActive = NO;
        GCControllerTouchpad *secondaryTouchpad = profile.touchpads[GCInputDualShockTouchpadTwo];
        if (secondaryTouchpad != nil) {
            GCControllerDirectionPad *touchSurface = secondaryTouchpad.touchSurface;
            secondaryTouchX = touchSurface.xAxis.value;
            secondaryTouchY = touchSurface.yAxis.value;
            secondaryTouchActive = secondaryTouchpad.touchState != GCTouchStateUp;
        }
        else if (profile.dpads[GCInputDualShockTouchpadTwo] != nil) {
            GCControllerDirectionPad *touch = profile.dpads[GCInputDualShockTouchpadTwo];
            secondaryTouchX = touch.xAxis.value;
            secondaryTouchY = touch.yAxis.value;
            secondaryTouchActive = secondaryTouchX != 0 || secondaryTouchY != 0;
        }

        BOOL hasMeaningfulInput = hasPressedButton ||
            fabs(leftX) >= 0.15 || fabs(leftY) >= 0.15 ||
            fabs(rightX) >= 0.15 || fabs(rightY) >= 0.15 ||
            primaryTouchActive || secondaryTouchActive;

        NSDictionary<NSNumber *, NSNumber *> *buttonStates = [capturedButtonStates copy];

        CFTimeInterval callbackCapturedAt = CACurrentMediaTime();
        recordControllerInputCallback(voidController, @"generic", profile,
                                      changedElement, changedElementName,
                                      buttonStates, elementDict, hasMeaningfulInput,
                                      leftX, leftY, rightX, rightY,
                                      leftTriggerValue, rightTriggerValue);

        // Use the same stable logical Start control for generic profiles. The
        // global menu-button value can lag behind the stream transition and
        // otherwise turn GameCube RT into the menu button.
        int radialMenuButton = ControllerElementStart;
        BOOL controllerNavigatorEnabled = NO;
        if (@available(iOS 13.0, tvOS 13.0, *)) {
            controllerNavigatorEnabled = ControllerNavigator.enabled;
        }
        dispatchControllerInputWork(self->_controllerInputQueue, ^{
            recordControllerInputWorkerDequeued(voidController, callbackCapturedAt);
            BOOL newlyClaimedSlot = NO;
            @synchronized (voidController) {
                if (!voidController.acceptsInput || voidController.gamepad != controller ||
                    voidController.inputOrderGeneration != orderGeneration) return;
                if (voidController.requiresButtonReleaseAfterOrderReset) {
                    if (!hasMeaningfulInput) voidController.requiresButtonReleaseAfterOrderReset = NO;
                }
                else if (!voidController.hasReceivedInput && hasMeaningfulInput) {
                    voidController.hasReceivedInput = YES;
                    newlyClaimedSlot = YES;
                }
            }

            // Claim the Sunshine port before applying the snapshot that caused
            // it, so the first input and P1 navigation stay in the same order.
            if (newlyClaimedSlot) {
                Log(LOG_I, @"Generic controller %@ received its first input; requesting a Sunshine port",
                    controller.vendorName ?: @"controller");
                [ControllerDiagnostics recordEvent:@"controller_first_input_claimed" fields:diagnosticCommonControllerFields(voidController)];
                [self->_controllerStreamLock lock];
                [self reportControllerArrivalLocked:voidController];
                [self->_controllerStreamLock unlock];
            }

            for (NSNumber *elementFlagId in buttonStates) {
                BOOL pressed = buttonStates[elementFlagId].boolValue;
                int buttonFlag = elementFlagId.intValue;
                // Trigger values travel in the dedicated analog trigger fields below;
                // their ControllerElement IDs are not Moonlight button flags.
                BOOL isTrigger = buttonFlag == ControllerElementLeftTrigger ||
                    buttonFlag == ControllerElementRightTrigger;
                if (isTrigger) {
                    CGFloat triggerValue = buttonFlag == ControllerElementLeftTrigger ? leftTriggerValue : rightTriggerValue;
                    @synchronized (voidController) {
                        BOOL wasPressed = buttonFlag == ControllerElementLeftTrigger
                            ? voidController.leftTriggerDigitallyPressed
                            : voidController.rightTriggerDigitallyPressed;
                        pressed = triggerValueIsDigitallyPressed(triggerValue, wasPressed);
                        if (buttonFlag == ControllerElementLeftTrigger) {
                            voidController.leftTriggerDigitallyPressed = pressed;
                        } else {
                            voidController.rightTriggerDigitallyPressed = pressed;
                        }
                    }
                }
                [self updateGyroSwitchForController:voidController buttonFlag:buttonFlag pressed:pressed];

                BOOL isStreamPrimary = voidController.streamPlayerIndex == 0;
                if (controllerNavigatorEnabled && isStreamPrimary && buttonFlag == radialMenuButton) {
                    BOOL changed = NO;
                    @synchronized (voidController) {
                        if (voidController.radialMenuButtonPressed != pressed) {
                            voidController.radialMenuButtonPressed = pressed;
                            changed = YES;
                        }
                    }
                    if (changed) {
                        recordStreamingRadialButtonSource(voidController, buttonFlag, pressed, changedElementName);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self->_controllerStreamLock lock];
                            BOOL stillPrimary = [self voidControllerForStreamPlayerIndexLocked:0] == voidController;
                            [self->_controllerStreamLock unlock];
                            if (stillPrimary) [ControllerNavigator handleStreamingRadialMenuButton:pressed];
                        });
                    }
                    // Start opens the radial menu, but it is also a real gamepad
                    // button and must remain visible to the streaming host.
                    UPDATE_BUTTON_FLAG(voidController, buttonFlag, pressed);
                }
                else if (!isTrigger) {
                    UPDATE_BUTTON_FLAG(voidController, buttonFlag, pressed);
                }
            }

            CGVector leftOffset = [ControllerUtil compensatedWithOffsetVector:CGVectorMake(leftX * self->stickMaxOffset,
                                                                                             leftY * self->stickMaxOffset)
                                                                     minOffset:self->_leftStickMinOffset
                                                                      circulate:false];
            CGVector rightOffset = [ControllerUtil compensatedWithOffsetVector:CGVectorMake(rightX * self->stickMaxOffset,
                                                                                              rightY * self->stickMaxOffset)
                                                                       minOffset:self->_rightStickMinOffset
                                                                        circulate:false];
            short leftStickX = (short)leftOffset.dx;
            short leftStickY = (short)leftOffset.dy;
            short rightStickX = (short)rightOffset.dx;
            short rightStickY = (short)rightOffset.dy;

            // Keep physical axes on their own controller. updateFinished merges
            // that state with OSC for P1; redirecting samples to OSC here can
            // leave a pre-assignment physical value stuck in the merged state.
            if (voidController.streamPlayerIndex == 0
                && [self useMotionHandler]
                && self->motionHandler.motionControlStarted
                && self->oscProfile.mapGyroTo == mapGyroToControllerStick
                && self->oscProfile.yawPitchToRightStick
                && self->_gyroEnabledFlag) {
                [self->motionHandler mixPhysicalRightStickAndGyroInputWithX:rightStickX y:rightStickY];
            }
            else {
                [self updateRightStick:voidController
                                     x:rightStickX
                                     y:rightStickY];
            }

            if (voidController.streamPlayerIndex == 0
                && [self useMotionHandler]
                && self->motionHandler.motionControlStarted
                && self->oscProfile.mapGyroTo == mapGyroToControllerStick
                && self->oscProfile.rollToLeftStick
                && self->_gyroEnabledFlag) {
                [self->motionHandler mixPhysicalLeftStickAndGyroInputWithX:leftStickX y:leftStickY];
            }
            else {
                [self updateLeftStick:voidController
                                    x:leftStickX
                                    y:leftStickY];
            }

            [self updateTriggers:voidController left:leftTrigger right:rightTrigger];
            [self updateFinished:voidController];

            [self handleControllerTouchpad:voidController
                                          x:primaryTouchX y:primaryTouchY
                                     active:primaryTouchActive index:0];
            [self handleControllerTouchpad:voidController
                                          x:secondaryTouchX y:secondaryTouchY
                                     active:secondaryTouchActive index:1];
        });
    }];
}

-(void) reinitiatePrimaryController {
    if(@available(iOS 13.0, *)){
        if(ControllerNavigator.controllerMouseEnabled){
            [ControllerNavigator startControllerMouse];
            return;
        }
        if(ControllerNavigator.radialMenuView) return;
    }
    if(![StreamFrameViewController sharedInstance]) return;
    MainFrameViewController* mainFrameVC =(MainFrameViewController* )ControllerUtil.delegate;
    if(mainFrameVC.settingsExpandedInStreamView) return;
    [ControllerUtil stopListeningPrimaryControllerWithStopListenToRadialMenuButton:true];
    if (@available(iOS 13.0, *)) [ControllerNavigator listenToRadialMenuButton];
    [self listenToGCController: ControllerUtil.primaryGCController];
    if (@available(iOS 13.0, *)){
        NSLog(@"ControllerUtil setUINavigationDelegate %f",CACurrentMediaTime());
        [ControllerNavigator setStreamFrameVCAsUINavigationDelegate];
    }
}

-(void) registerControllerCallbacks:(GCController*) controller
{
    if (controller != NULL) {
        if (@available(iOS 14.0, tvOS 14.0, *)) {
            // Keep HID callbacks off the main UI queue while a stream is active.
            controller.handlerQueue = _controllerInputQueue;
        }

        // iOS 13 allows the Start button to behave like a normal button, however
        // older MFi controllers can send an instant down+up event for the start button
        // which means the button will not be down long enough to register on the PC.
        // To work around this issue, use the old controllerPausedHandler if the controller
        // doesn't have a Select button (which indicates it probably doesn't have a proper
        // Start button either).
        BOOL useLegacyPausedHandler = YES;
        if (@available(iOS 13.0, tvOS 13.0, *)) {
            if (controller.extendedGamepad != nil &&
                controller.extendedGamepad.buttonOptions != nil) {
                useLegacyPausedHandler = NO;
            }
        }
        if (@available(iOS 16.0, tvOS 16.0, *)) {
            if (controller.extendedGamepad == nil &&
                controller.physicalInputProfile.buttons[GCInputButtonMenu] != nil) {
                // The generic-profile listener sends Menu as Start. Avoid sending a
                // second, synthetic Start press through the legacy pause handler.
                useLegacyPausedHandler = NO;
            }
        }

        controller.controllerPausedHandler = NULL;
        
        if (useLegacyPausedHandler) {
            controller.controllerPausedHandler = ^(GCController *controller) {
                [self->_controllerStreamLock lock];
                VoidController* voidController = [self voidControllerForGamepadLocked:controller];
                [self->_controllerStreamLock unlock];
                if (voidController == nil) return;
                
                // Get off the main thread
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                    [self setButtonFlag:voidController flags:PLAY_FLAG];
                    [self updateFinished:voidController];
                    
                    // Pause for 100 ms
                    usleep(100 * 1000);
                    
                    [self clearButtonFlag:voidController flags:PLAY_FLAG];
                    [self updateFinished:voidController];
                });
            };
        }
        
        if ([ControllerSupport isSupportedGamepad:controller]) {
            if (@available(iOS 14.0, tvOS 14.0, *)) {
                for (GCControllerElement* element in controller.physicalInputProfile.allElements) {
                    element.preferredSystemGestureState = GCSystemGestureStateDisabled;
                }
            }

            if (controller.extendedGamepad != nil && controller == ControllerUtil.primaryGCController) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [self reinitiatePrimaryController];
                });
            }
            else if (controller.extendedGamepad != nil) {
                [self listenToGCController:controller];
            }
            else if (@available(iOS 16.0, tvOS 16.0, *)) {
                [self listenToGenericGCController:controller];
            }

            VoidController *voidController = [self voidControllerForGamepadLocked:controller];
            NSMutableDictionary<NSString *, id> *fields = voidController
                ? [NSMutableDictionary dictionaryWithDictionary:diagnosticCommonControllerFields(voidController)]
                : [NSMutableDictionary dictionary];
            fields[@"listener"] = controller.extendedGamepad != nil ? @"extended_gamepad" : @"generic_physical_profile";
            fields[@"legacy_pause_handler"] = @(useLegacyPausedHandler);
            fields[@"physical_elements"] = controller.physicalInputProfile.elements.allKeys ?: @[];
            [ControllerDiagnostics recordEvent:@"controller_callbacks_registered" fields:fields];
        }
    } else {
        Log(LOG_W, @"Tried to register controller callbacks on NULL controller");
    }
}

-(void) unregisterMouseCallbacks:(GCMouse*)mouse API_AVAILABLE(ios(14.0)) {
    mouse.mouseInput.mouseMovedHandler = nil;
    
    mouse.mouseInput.leftButton.pressedChangedHandler = nil;
    mouse.mouseInput.middleButton.pressedChangedHandler = nil;
    mouse.mouseInput.rightButton.pressedChangedHandler = nil;
    
    for (GCControllerButtonInput* auxButton in mouse.mouseInput.auxiliaryButtons) {
        auxButton.pressedChangedHandler = nil;
    }
    
#if TARGET_OS_TV
    mouse.mouseInput.scroll.xAxis.valueChangedHandler = nil;
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = nil;
#endif
}

-(void) registerMouseCallbacks:(GCMouse*) mouse API_AVAILABLE(ios(14.0)) {
    if (_captureMouse){
        mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput * _Nonnull mouse, float deltaX, float deltaY) {
            self->accumulatedDeltaX += deltaX / MOUSE_SPEED_DIVISOR;
            self->accumulatedDeltaY += -deltaY / MOUSE_SPEED_DIVISOR;
            
            short truncatedDeltaX = (short)self->accumulatedDeltaX;
            short truncatedDeltaY = (short)self->accumulatedDeltaY;
            
            if (truncatedDeltaX != 0 || truncatedDeltaY != 0) {
                LiSendMouseMoveEvent(truncatedDeltaX, truncatedDeltaY);
                
                self->accumulatedDeltaX -= truncatedDeltaX;
                self->accumulatedDeltaY -= truncatedDeltaY;
            }
        };
    } else {
        mouse.mouseInput.mouseMovedHandler = nil;
    }

    
    mouse.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    };
    mouse.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_MIDDLE);
    };
    mouse.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
    };
    
    if (mouse.mouseInput.auxiliaryButtons != nil) {
        if (mouse.mouseInput.auxiliaryButtons.count >= 1) {
            mouse.mouseInput.auxiliaryButtons[0].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X1);
            };
        }
        if (mouse.mouseInput.auxiliaryButtons.count >= 2) {
            mouse.mouseInput.auxiliaryButtons[1].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X2);
            };
        }
    }
    
    // We use UIPanGestureRecognizer on iPadOS because it allows us to distinguish
    // between discrete and continuous scroll events and also works around a bug
    // in iPadOS 15 where discrete scroll events are dropped. tvOS only supports
    // GCMouse for mice, so we will have to just use it and hope for the best.
#if TARGET_OS_TV
    mouse.mouseInput.scroll.xAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        self->accumulatedScrollX += value;
        
        short truncatedScrollX = (short)self->accumulatedScrollX;
        
        if (truncatedScrollX != 0) {
            // Direction is reversed from vertical scrolling
            LiSendHighResHScrollEvent(-truncatedScrollX * 20);
            
            self->accumulatedScrollX -= truncatedScrollX;
        }
    };
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        self->accumulatedScrollY += value;
        
        short truncatedScrollY = (short)self->accumulatedScrollY;
        
        if (truncatedScrollY != 0) {
            LiSendHighResScrollEvent(truncatedScrollY * 20);
            
            self->accumulatedScrollY -= truncatedScrollY;
        }
    };
#endif
}

-(void) updateAutoOnScreenControlMode
{
    // Auto on-screen control support may not be enabled
    if (_osc == NULL) {
        return;
    }
    
    OnScreenControlsLevel level = OnScreenControlsLevelFull;
    
    // We currently stop after the first controller we find.
    // Maybe we'll want to change that logic later.
    for (int i = 0; i < [[GCController controllers] count]; i++) {
        GCController *controller = [GCController controllers][i];
        
        if (controller != NULL) {
            if (controller.extendedGamepad == NULL && [ControllerSupport isSupportedGamepad:controller]) {
                level = OnScreenControlsLevelOff;
                break;
            }

            if (controller.extendedGamepad != NULL) {
                level = OnScreenControlsLevelAutoGCExtendedGamepad;
                if (@available(iOS 12.1, tvOS 12.1, *)) {
                    if (controller.extendedGamepad.leftThumbstickButton != nil &&
                        controller.extendedGamepad.rightThumbstickButton != nil) {
                        level = OnScreenControlsLevelAutoGCExtendedGamepadWithStickButtons;
                        if (@available(iOS 13.0, tvOS 13.0, *)) {
                            if (controller.extendedGamepad.buttonOptions != nil) {
                                // Has L3/R3 and Select, so we can show nothing :)
                                level = OnScreenControlsLevelOff;
                            }
                        }
                    }
                }
                break;
            }
        }
    }
    
    // If we didn't find a gamepad present and we have a keyboard or mouse, turn
    // the on-screen controls off to get the overlays out of the way.
    if (level == OnScreenControlsLevelFull && [ControllerSupport hasKeyboardOrMouse]) {
        level = OnScreenControlsLevelOff;
        
        // Ensure the virtual gamepad disappears to avoid confusing some games.
        // If the mouse and keyboard disconnect later, it will reappear when the
        // first OSC input is received.
        LiSendMultiControllerEvent(0, 0, 0, 0, 0, 0, 0, 0, 0);
    }
    
    [_osc setLevel:level];
}

-(void) initAutoOnScreenControlMode:(OnScreenControls*)osc
{
    _osc = osc;
    
    [self updateAutoOnScreenControlMode];
}

- (void)updateVoidController:(VoidController* )voidController withGCController:(GCController* )controller{
    //voidController.playerIndex = controller.playerIndex == -1 ? 0 : (uint8_t) controller.playerIndex;
    voidController.motionTypes = [[NSMutableSet alloc] init];
    voidController.supportedEmulationFlags = EMULATING_SPECIAL | EMULATING_SELECT;
    voidController.gamepad = controller;
    if (voidController.diagnosticID == nil) voidController.diagnosticID = NSUUID.UUID.UUIDString;
    // Every physical device waits for a deliberate button press before taking
    // a Sunshine port. This also covers ordinary Bluetooth gamepads.
    voidController.waitsForInputBeforeArrival = YES;
#if !TARGET_OS_TV
    if ([GameSirG8MFiRumbler isTargetController:controller]) {
        voidController.hardware = ControllerHardwareG8PlusMFi;
    } else if ([_kishiRumbler isTargetController:controller]) {
        voidController.hardware = ControllerHardwareRazerKishi;
    } else {
        voidController.hardware = ControllerHardwareGeneric;
    }
#else
    voidController.hardware = ControllerHardwareGeneric;
#endif
    voidController.hasAccelerometer = NO;
    voidController.hasGyroscope = NO;

    
    if([ControllerUtil hasControllerAccelerometer:voidController.gamepad]){
        [voidController.motionTypes addObject:@(LI_MOTION_TYPE_ACCEL)];
        voidController.hasAccelerometer = YES;
        voidController.reportRateHz = 120;
    }
    if (@available(iOS 14.0, *)) {
        if(voidController.gamepad.motion.hasRotationRate) {
            [voidController.motionTypes addObject:@(LI_MOTION_TYPE_GYRO)];
            voidController.hasGyroscope = YES;
            voidController.reportRateHz = 120;
        }
    }

    // The OSC merge is selected when this device receives Sunshine port 0.
    // Connection order and adapter endpoint order must not decide that.
    voidController.mergedWithController = nil;
    if (_oscController.mergedWithController == voidController) {
        _oscController.mergedWithController = nil;
    }
    
    if (@available(iOS 13.0, tvOS 13.0, *)) {
        if (controller.extendedGamepad != nil &&
            controller.extendedGamepad.buttonOptions != nil) {
            // Disable select button emulation since we have a physical select button
            voidController.supportedEmulationFlags &= ~EMULATING_SELECT;
        }
    }
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        if (controller.extendedGamepad != nil &&
            controller.extendedGamepad.buttonHome != nil) {
            // Disable special button emulation since we have a physical special button
            voidController.supportedEmulationFlags &= ~EMULATING_SPECIAL;
        }

        if (controller.extendedGamepad == nil) {
            NSDictionary<NSString *, GCControllerButtonInput *> *buttons = controller.physicalInputProfile.buttons;
            if (buttons[GCInputButtonOptions] != nil) {
                voidController.supportedEmulationFlags &= ~EMULATING_SELECT;
            }
            if (buttons[GCInputButtonHome] != nil) {
                voidController.supportedEmulationFlags &= ~EMULATING_SPECIAL;
            }
        }
    }
    
    // Prepare controller haptics for use
    [self initializeControllerHaptics:voidController];
}

-(VoidController* )assignController:(GCController*)controller {
    // Callers hold _controllerStreamLock so slot allocation cannot race event masks.
    VoidController* existingController = [self voidControllerForGamepadLocked:controller];
    if (existingController != nil) {
        VoidController* voidController = existingController;
        @synchronized (voidController) {
            voidController.acceptsInput = YES;
        }
        [self updateVoidController:voidController withGCController:controller];
        return voidController;
    }

    // Use a local key only for bookkeeping. Empty generic adapter endpoints may
    // outnumber Sunshine's four remote ports, so local keys do not consume them.
    int localIndex = 0;
    while (localIndex < 32 && [_voidControllers objectForKey:@(localIndex)] != nil) localIndex++;
    if (localIndex >= 32) {
        Log(LOG_W, @"Too many local game controller endpoints; ignoring %@", controller.vendorName ?: @"controller");
        return nil;
    }

    VoidController* voidController = [[VoidController alloc] init];
    voidController.diagnosticID = NSUUID.UUID.UUIDString;
    voidController.playerIndex = localIndex;
    voidController.streamPlayerIndex = -1;
    @synchronized (voidController) {
        voidController.acceptsInput = YES;
    }
    [ControllerUtil.activeStreamingGCControllers addObject:controller];
    if (localIndex < 4) controller.playerIndex = localIndex;
    [self updateVoidController:voidController withGCController:controller];
    [_voidControllers setObject:voidController forKey:@(localIndex)];

    Log(LOG_I, @"Tracking controller endpoint locally as %d; waiting for its first button press", localIndex);
    NSMutableDictionary<NSString *, id> *fields = [NSMutableDictionary dictionaryWithDictionary:diagnosticCommonControllerFields(voidController)];
    fields[@"waits_for_input_before_arrival"] = @(voidController.waitsForInputBeforeArrival);
    fields[@"physical_elements"] = controller.physicalInputProfile.elements.allKeys ?: @[];
    [ControllerDiagnostics recordEvent:@"controller_endpoint_assigned_locally" fields:fields];
    return voidController;
}

-(VoidController*) getOscController {
    return _oscController;
}

+(bool) isSupportedGamepad:(GCController*) controller {
    if (controller.extendedGamepad != nil) {
        return true;
    }

    if (@available(iOS 16.0, tvOS 16.0, *)) {
        GCPhysicalInputProfile *profile = controller.physicalInputProfile;
        BOOL hasFaceButton = profile.buttons[GCInputButtonA] != nil
            || profile.buttons[GCInputButtonB] != nil
            || profile.buttons[GCInputButtonX] != nil
            || profile.buttons[GCInputButtonY] != nil;
        BOOL hasDirectionOrStick = profile.dpads[GCInputDirectionPad] != nil
            || profile.dpads[GCInputLeftThumbstick] != nil
            || profile.dpads[GCInputRightThumbstick] != nil;
        return hasFaceButton && hasDirectionOrStick;
    }

    return false;
}

#pragma clang diagnostic pop

+(int) getGamepadCount {
    int count = 0;
    
    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            count++;
        }
    }
    
    return count;
}

+(int) getConnectedGamepadMask:(StreamConfiguration*)streamConfig {
    // Physical controller ports arrive on a deliberate button press. Preserve
    // the legacy single-pad startup bit; multi-pad starts with no physical pads.
    int mask = streamConfig.multiController ? 0 : 0x1;
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* settings = [dataMan getSettings];
    OnScreenControlsLevel level = (OnScreenControlsLevel)[settings.onscreenControls integerValue];
    
    // Even if no gamepads are present, we will always count one if OSC is enabled,
    // or it's set to auto and no keyboard or mouse is present. Absolute touch mode
    // disables the OSC.
    if (level != OnScreenControlsLevelOff && (![ControllerSupport hasKeyboardOrMouse] || level != OnScreenControlsLevelAuto) && (settings.touchMode.intValue == RelativeTouch)) {
        mask |= 0x1;
    }
    
    return mask;
}

-(NSUInteger) getConnectedGamepadCount
{
    NSUInteger count = 0;
    for (VoidController* controller in _voidControllers.allValues) {
        if (controller.reportedArrival) count++;
    }
    return count;
}

- (void)assignControllers{
    [_controllerStreamLock lock];
    for (GCController* controller in [GCController controllers]) {
        NSLog(@"controller count: iterating");
        recordControllerDiscovery(controller, @"stream_start_enumeration");
        
        if ([ControllerSupport isSupportedGamepad:controller]) {
            NSLog(@"controller count: is supported,is contained by dict: %d", [ControllerUtil.activeStreamingGCControllers containsObject:controller]);
                NSLog(@"controller obj +1 in dic");
                VoidController* assignedController = [self assignController:controller];
                NSLog(@"controller obj num in dict: %lu", (unsigned long)_voidControllers.allValues.count);
                if (assignedController) [self registerControllerCallbacks:controller];
            // Note: We cannot report controller arrival to the host here,
            // because the connection has not been established yet.play
        }
    }
    [_controllerStreamLock unlock];
    NSLog(@"device gyro codes,update gyroMode: %d, controller count: %lu", _gyroMode, (unsigned long)_voidControllers.count);
}

- (void)updateCommonConfig:(StreamConfiguration* )streamConfig{
    // Drain captured controller input before replacing configuration used by
    // the serial input worker. Callers run on main, so callbacks cannot enqueue
    // more work until this barrier and the configuration update have finished.
    dispatch_sync(_controllerInputQueue, ^{});

    _streamConfig = streamConfig;
    _multiController = streamConfig.multiController;
    _swapABXYButtons = streamConfig.swapABXYButtons;

    _oscController.playerIndex = 0;
    _oscController.streamPlayerIndex = 0;

    oscProfile = [oscProfileMan getSelectedProfile];
    motionHandler = [MotionHandler sharedWithProfile:oscProfile];
    DataManager* dataMan = [[DataManager alloc] init];
    tempSettings = [dataMan getSettings];

    _oscEnabled = _oscEnabled || (OnScreenControlsLevel)[tempSettings.onscreenControls integerValue] != OnScreenControlsLevelOff || streamConfig.gyroMode != GyroModeOff;
    _gyroSensitivity = tempSettings.gyroSensitivity.floatValue;
    
    if (@available(iOS 13.0, *)) {
        _controllerNavigationEnabled = ControllerNavigator.enabled;
        [ControllerNavigator configureControllerMouseWith:tempSettings];
    }
    
    @synchronized (self) {
        _controllerGyroSwitchEnabled = oscProfile.controllerGyroSwitchMode != ControllerGyroSwitchDisabled;
        _gyroSwitchMode = oscProfile.controllerGyroSwitchMode;
        // _gyroSwitchMode = ControllerGyroSwitchHoldDownToActivate;
        _controllerGyroSwitchToggle = oscProfile.controllerGyroSwitchToggle;
        _controllerGyroSwitchHold = oscProfile.controllerGyroSwitchHold;
        _reverseHoldButton = oscProfile.reverseGyroHoldButton;
        _gyroToggleEnabled = NO;
        _controllerGyroSwitchTogglePressedMask = 0;
        _controllerGyroSwitchHoldPressedMask = 0;

        // if(oscProfile.controllerGyroSwitchMode == ControllerGyroSwitchDisabled && ![self useMotionHandler]) _gyroEnabledFlag = false;
        _gyroEnabledFlag = false;
        [self->motionHandler stopMotionUpdateWithInterruptNoneGyroInput:false];
    }
    
    stickMaxOffset = 0x7FFE;
    _leftStickMinOffset = oscProfile.physicalLeftStickMinOffset;
    _rightStickMinOffset = oscProfile.physicalRightStickMinOffset;

    [ControllerDiagnostics recordEvent:@"controller_stream_configured" fields:@{
        @"multi_controller": @(_multiController),
        @"swap_abxy": @(_swapABXYButtons),
        @"controller_navigation_enabled": @(_controllerNavigationEnabled),
        @"emulated_controller_type": @(streamConfig.emulatedControllerType),
        @"trigger_deadzone": @(ControllerUtil.controllerTriggerDeadzone)
    }];

}

- (void)resetGyroInputForController:(VoidController* )voidController{
    if(voidController.hasAccelerometer) LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,LI_MOTION_TYPE_ACCEL,0,0,0);
    if(voidController.hasGyroscope) LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,LI_MOTION_TYPE_GYRO,0,0,0);
    if (@available(iOS 14.0, *)) {
        voidController.gamepad.motion.sensorsActive = false;
    }
}

- (void)stopTimerForAllControllers{
    [self stopTimerForController:_oscController];
    for(VoidController* controller in _voidControllers.allValues){
        [self stopTimerForController:controller];
    }
}

- (void)updateControllerSupport:(StreamConfiguration*)streamConfig delegate:(id<ControllerSupportDelegate>)delegate {
    NSLog(@"update config call");
    
    [self updateCommonConfig:streamConfig];
    _gyroMode = streamConfig.gyroMode;
    
    Log(LOG_I, @"Number of supported controllers connected: %d", [ControllerSupport getGamepadCount]);
    Log(LOG_I, @"Multi-controller: %d", _multiController);
    
    [self applyGyroModeSetting];
    
    [self assignControllers];
    
    NSLog(@"controllerNumbers: %d", _controllerNumbers);

    for(VoidController* controller in _voidControllers.allValues){
        NSLog(@"controller obj in dict: %@", controller);
    }
    
    if([self psGyroEnabledInSetting]) [self updateFinished:_oscController];
}

-(id)initWithConfig:(StreamConfiguration*)streamConfig delegate:(id<ControllerSupportDelegate>)delegate
{
    self = [super init];
    if (self) {
        VLSharedControllerSupport = self;
        atomic_init(&_gyroEnabledFlag, false);
    }
    
    NSLog(@"controller support init");
        
    _delegate = delegate;
    _controllerStreamLock = [[NSLock alloc] init];
    dispatch_queue_attr_t inputQueueAttributes = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    _controllerInputQueue = dispatch_queue_create(
        "com.voidlink.controller-input", inputQueueAttributes);
    dispatch_queue_set_specific(_controllerInputQueue,
                                &controllerInputQueueSpecificKey,
                                &controllerInputQueueSpecificKey,
                                NULL);
    _voidControllers = [[NSMutableDictionary alloc] init];
    [ControllerUtil beginStreamingPrimaryControllerSelection];
    [ControllerUtil.activeStreamingGCControllers removeAllObjects];
    _controllerNumbers = 0;
    _reservedControllerNumbers = 0;
#if !TARGET_OS_TV
    _gameSirG8MFiRumbler = [[GameSirG8MFiRumbler alloc] init];
    _kishiRumbler = [[KishiV3ProXLRumbler alloc] init];
#endif
    
    _captureMouse = (streamConfig.localMousePointerMode == 0);
    if (@available(iOS 14.0, tvOS 14.0, *)) {
            for (GCMouse* mouse in [GCMouse mice]) {
                [self registerMouseCallbacks:mouse];
            }
        }
    
    _controllerConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
    Log(LOG_I, @"Controller connected!");
    
    GCController* controller = note.object;
    recordControllerDiscovery(controller, @"connect_notification");
    
    if (![ControllerSupport isSupportedGamepad:controller]) {
        // Ignore micro gamepads and motion controllers
        return;
    }

    
    //[self->_activeGCControllers addObject:controller];
    [self->_controllerStreamLock lock];
    VoidController* voidController = [self assignController:controller];
    if (voidController) {
        // Register callbacks and announce the slot atomically with respect to input events.
        [self registerControllerCallbacks:controller];
        [self reportControllerArrivalLocked:voidController];
    }
    [self->_controllerStreamLock unlock];

    if (voidController) {
            // Re-evaluate the on-screen control mode
            //[self updateAutoOnScreenControlMode];
            if((self->_gyroMode == GyroModeAuto && [self externalControllersHaveGyro]) || self->_gyroMode == AlwaysController){
                [self stopTimerForController:self->_oscController];
                [self updateTimerStateForController:voidController];
            }
            
            // Notify the delegate
            [self->_delegate gamepadPresenceChanged];
        }
}];
    
    _controllerDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        Log(LOG_I, @"Controller disconnected!");
        
        GCController* controller = note.object;
        
        if (![ControllerSupport isSupportedGamepad:controller]) {
            // Ignore micro gamepads and motion controllers
            return;
        }


        BOOL disconnectedStreamPrimary = NO;
        [self->_controllerStreamLock lock];
        VoidController* voidController = [self voidControllerForGamepadLocked:controller];
        if (voidController != nil) {
            disconnectedStreamPrimary = voidController.streamPlayerIndex == 0;
            @synchronized (voidController) {
                voidController.acceptsInput = NO;
            }
        }
        [self->_controllerStreamLock unlock];

        NSMutableDictionary<NSString *, id> *disconnectFields = voidController
            ? [NSMutableDictionary dictionaryWithDictionary:diagnosticCommonControllerFields(voidController)]
            : [NSMutableDictionary dictionaryWithDictionary:@{
                @"vendor": controller.vendorName ?: @"unknown",
                @"product_category": controller.productCategory ?: @"unknown",
                @"profile": controller.extendedGamepad != nil ? @"extended" : @"generic"
            }];
        disconnectFields[@"reported_arrival"] = @(voidController.reportedArrival);
        disconnectFields[@"had_received_input"] = @(voidController.hasReceivedInput);
        [ControllerDiagnostics recordEvent:@"controller_disconnected" fields:disconnectFields];

        [self unregisterControllerCallbacks:controller];
        // Finish already-captured controller input before its player slot can be reused.
        dispatch_sync(self->_controllerInputQueue, ^{});
        if (voidController && voidController.reportedArrival) {
            if (voidController.streamPlayerIndex == 0) {
                [self->motionHandler resetPhysicalStickInputs];
            }

            // Release contacts while the controller slot is still active on the host.
            [self releaseControllerTouchpadContacts:voidController];

            // The host expects a zeroed event when a controller slot is removed.
            // Clear its cached state before updateFinished reports the new mask.
            @synchronized (voidController) {
                voidController.lastButtonFlags = 0;
                voidController.emulatingButtonFlags = 0;
                voidController.lastLeftTrigger = 0;
                voidController.lastRightTrigger = 0;
                voidController.leftTriggerDigitallyPressed = NO;
                voidController.rightTriggerDigitallyPressed = NO;
                voidController.lastLeftStickX = 0;
                voidController.lastLeftStickY = 0;
                voidController.lastRightStickX = 0;
                voidController.lastRightStickY = 0;
            }
        }

        if (voidController) [self resetGyroSwitchForPlayerIndex:voidController.playerIndex];
        
        if([ControllerUtil.activeStreamingGCControllers containsObject:controller]){
            [ControllerUtil.activeStreamingGCControllers removeObject:controller];
            [self->_controllerStreamLock lock];
            if (voidController.streamPlayerIndex >= 0) {
                self->_controllerNumbers &= ~(1 << voidController.streamPlayerIndex);
                self->_reservedControllerNumbers &= ~(1 << voidController.streamPlayerIndex);
            }
            [self->_controllerStreamLock unlock];
        }
        if (disconnectedStreamPrimary) [ControllerUtil setStreamingPrimaryController:nil];
        Log(LOG_I, @"Unassigning controller endpoint %ld from Sunshine port %d", (long)(voidController ? voidController.playerIndex : -1), voidController ? voidController.streamPlayerIndex : -1);

        if (voidController) {
#if !TARGET_OS_TV
            if ([self->_kishiRumbler isTargetController:controller]) {
                [self->_kishiRumbler stopAndClose];
            }
            if ([GameSirG8MFiRumbler isTargetController:controller]) {
                [self->_gameSirG8MFiRumbler stopAndClose];
            }
#endif
            [self stopTimerForController:voidController];
            
            // Stop haptics on this controller
            [self cleanupControllerHaptics:voidController];
            
            // Stop motion reports on this controller
            [self cleanupControllerMotion:voidController];
            
            // Stop battery reports on this controller
            [self cleanupControllerBattery:voidController];
            
            // Disassociate this controller from any controllers merged with it
            if (voidController.mergedWithController) {
                if(voidController.mergedWithController.mergedWithController == voidController) voidController.mergedWithController.mergedWithController = nil;
            }
            
            // Inform the server of the updated active gamepads before removing this controller
            if (!voidController.reportedArrival) {
                @synchronized (voidController) {
                    voidController.hasReceivedInput = NO;
                }
            }
            [self updateFinished:voidController];
            
            // Re-evaluate the on-screen control mode
            //[self updateAutoOnScreenControlMode];
            
            [self->_controllerStreamLock lock];
            [self->_voidControllers removeObjectForKey:@(voidController.playerIndex)];
            [self->_controllerStreamLock unlock];
            
            if((self->_voidControllers.allValues.count == 0 || ![self externalControllersHaveGyro]) && self->_gyroMode == GyroModeAuto) [self updateTimerStateForController:self->_oscController];
            
            // Notify the delegate
            [self->_delegate gamepadPresenceChanged];
        }
    }];
    
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        
        _mouseConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Mouse connected!");
            
            GCMouse* mouse = note.object;
            
            // Register for mouse events
            [self registerMouseCallbacks: mouse];
            
            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
            
            // Notify the delegate
            [self->_delegate mousePresenceChanged];
            [self->_delegate mouseConnected];
        }];
        _mouseDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Mouse disconnected!");
            
            GCMouse* mouse = note.object;
            
            // Unregister for mouse events
            [self unregisterMouseCallbacks: mouse];
            
            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
            
            // Notify the delegate
            [self->_delegate mousePresenceChanged];
        }];
        _keyboardConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCKeyboardDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Keyboard connected!");
            
            [self->_delegate keyboardConnected];
            
            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
        }];
        _keyboardDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCKeyboardDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Keyboard disconnected!");
            
            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
        }];
        //for(Controller* controller in _controllers) [self updateTimerStateForController:controller];
    }
    

    
    _oscController = [[VoidController alloc] init];
    [self initializeControllerHaptics:_oscController];
    _gyroMode = AlwaysDevice;

    // _controllerMouseEnabledFlag = false;
    
    _gyroEnabledFlag = false;
    oscProfileMan = [OSCProfilesManager sharedManager:CGRectZero];

    [self updateCommonConfig:streamConfig];
    
    for(VoidController* voidController in _voidControllers.allValues){
        NSLog(@"stop external controller timer %@", voidController);
        [self stopTimerForController:voidController];
    }
    [self updateTimerStateForController:_oscController];

    [self assignControllers];
    
    _shallDisableGyroHotSwitch = streamConfig.gyroMode == GyroModeOff && _voidControllers.allValues.count == 0;
    NSLog(@"shallDisableGyroHotSwitch %d", _shallDisableGyroHotSwitch);
    
    
    return self;
}

-(bool)externalControllersHaveGyro{
    for(VoidController* voidController in _voidControllers.allValues){
        if(voidController.hasGyroscope || voidController.hasAccelerometer) return true;
    }
    return false;
}

-(bool)psGyroEnabledInSetting {
    uint8_t emulation = tempSettings.emulatedControllerType.intValue;
    return (emulation == ControllerEmulationPs
            || emulation == ControllerEmulationPsEnhancedHaptic
            || emulation == ControllerEmulationXboxAndPs)
            && tempSettings.gyroMode.intValue != GyroModeOff;
}

-(void)connectionEstablished {
    NSMutableArray<NSDictionary<NSString *, id> *> *endpoints = [NSMutableArray array];
    for (VoidController *controller in _voidControllers.allValues) {
        [endpoints addObject:@{
            @"device_id": controller.diagnosticID ?: @"unknown",
            @"local_endpoint": @(controller.playerIndex),
            @"sunshine_port": controller.streamPlayerIndex >= 0 ? @(controller.streamPlayerIndex + 1) : @0,
            @"waits_for_input": @(controller.waitsForInputBeforeArrival),
            @"has_received_input": @(controller.hasReceivedInput),
            @"arrival_reported": @(controller.reportedArrival)
        }];
    }
    [ControllerDiagnostics recordEvent:@"stream_connection_established" fields:@{
        @"multi_controller": @(_multiController),
        @"active_port_mask": @([self getActiveGamepadMask]),
        @"controller_endpoints": endpoints
    }];

    for (VoidController* voidController in _voidControllers.allValues) {
        if (voidController.waitsForInputBeforeArrival) {
            if (!voidController.hasReceivedInput && !voidController.didLogArrivalDeferred) {
                voidController.didLogArrivalDeferred = YES;
                [ControllerDiagnostics recordEvent:@"controller_arrival_waiting_for_first_input"
                                             fields:diagnosticCommonControllerFields(voidController)];
            }
            [self updateFinished:voidController];
        }
    }
    
    //if (_oscEnabled
    //  || (tempSettings.emulatedControllerType.intValue == LI_CTYPE_PS && tempSettings.gyroMode != GyroModeOff)) {
    if ([self psGyroEnabledInSetting]) {
        [self setButtonFlag:self->_oscController flags:A_FLAG];
        [self updateFinished:self->_oscController];
        [self clearButtonFlag:self->_oscController flags:A_FLAG];
        [self updateFinished:self->_oscController];
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self->_gyroMode = self->_streamConfig.gyroMode;
        
        [self applyGyroModeSetting];
    });
}

-(void)stopTimerForController:(VoidController* )voidController{
    [self resetGyroInputForController:voidController];
    if (@available(iOS 14.0, *)) {
        //NSLog(@"stop controller obj: %@, hasAcc %d, hasGyro %d", voidController, voidController.hasAccelerometer, voidController.hasGyroscope);
        // if(voidController.hasAccelerometer){
            [voidController.accelTimer invalidate];
            voidController.accelTimer = nil;
        // }
        // if(voidController.hasGyroscope){
            [voidController.gyroTimer invalidate];
            voidController.gyroTimer = nil;
        // }
    }
}

- (void)applyGyroModeSetting {
    // Stop all timers to ensure a clean slate before applying the new setting.
    [self stopTimerForAllControllers];

    @synchronized (self) {
        _gyroEnabledFlag = [self psGyroEnabledInSetting];
        _gyroToggleEnabled = _gyroEnabledFlag;
    }
    switch(_gyroMode) {
        case AlwaysController:
            // Activate timers only for physical controllers.
            for (VoidController* voidController in _voidControllers.allValues) {
                if(voidController == _oscController) break;
                [self updateTimerStateForController:voidController];
            }
            break;

        case GyroModeAuto:
            // Prefer physical controller gyros if they exist.
            if ([self externalControllersHaveGyro]) {
                for (VoidController* voidController in _voidControllers.allValues) {
                    [self updateTimerStateForController:voidController];
                }
            } else {
                // Otherwise, fall back to the device gyro.
                [self updateTimerStateForController:self->_oscController];
            }
            break;

        case AlwaysDevice:
            // Always start the device gyro in this mode.
            [self updateTimerStateForController:self->_oscController];
            break;
            
        case GyroModeOff:
            // Do nothing, all timers are already stopped.
            break;
    }
}

- (void)updateTimerStateForOsc{
    [self updateTimerStateForController:self->_oscController];
}

-(void) cleanup
{
    [ControllerDiagnostics recordEvent:@"controller_support_cleanup" fields:@{
        @"endpoint_count": @(_voidControllers.count),
        @"active_port_mask": @([self getActiveGamepadMask])
    }];
    @synchronized (self) {
        _isCleaningUp = YES;
    }

    [ControllerUtil stopAllDualSenseHaptics];
#if !TARGET_OS_TV
    [_gameSirG8MFiRumbler invalidate];
    [_kishiRumbler invalidate];
#endif

    if (VLSharedControllerSupport == self) {
        VLSharedControllerSupport = nil;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:_controllerConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_controllerDisconnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_mouseConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_mouseDisconnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_keyboardConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_keyboardDisconnectObserver];
    
    _controllerConnectObserver = nil;
    _controllerDisconnectObserver = nil;
    _mouseConnectObserver = nil;
    _mouseDisconnectObserver = nil;
    _keyboardConnectObserver = nil;
    _keyboardDisconnectObserver = nil;

    [_controllerStreamLock lock];
    for (VoidController* controller in _voidControllers.allValues) {
        @synchronized (controller) {
            controller.acceptsInput = NO;
        }
    }
    [_controllerStreamLock unlock];

    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            [self unregisterControllerCallbacks:controller];
        }
    }
    // Drain captured controller input before releasing its state.
    dispatch_sync(_controllerInputQueue, ^{});
    @synchronized (self) {
        _controllerGyroSwitchTogglePressedMask = 0;
        _controllerGyroSwitchHoldPressedMask = 0;
    }
    
    [_controllerStreamLock lock];
    _controllerNumbers = 0;
    _reservedControllerNumbers = 0;
    [_controllerStreamLock unlock];
    
    [self stopTimerForController:_oscController];
    NSArray<VoidController *> *controllersToCleanUp = nil;
    [_controllerStreamLock lock];
    controllersToCleanUp = [_voidControllers.allValues copy];
    [_controllerStreamLock unlock];
    for (VoidController* controller in controllersToCleanUp) {
        [self stopTimerForController:controller];
        [self cleanupControllerHaptics:controller];
        [self cleanupControllerMotion:controller];
        [self cleanupControllerBattery:controller];
    }
    [_controllerStreamLock lock];
    [_voidControllers removeAllObjects];
    [_controllerStreamLock unlock];
    [ControllerUtil endStreamingPrimaryControllerSelection];
    
    #if !TARGET_OS_TV
        [self cleanupControllerMotion:_oscController];
        [_oscController.motionManager stopDeviceMotionUpdates];
    #endif
    
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        for (GCMouse* mouse in [GCMouse mice]) {
            [self unregisterMouseCallbacks:mouse];
        }
    }
}


- (void) dealloc
{
    if (VLSharedControllerSupport == self) {
        VLSharedControllerSupport = nil;
    }
}

@end
