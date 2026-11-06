//
//  Settings.x
//  NeoFreeBird
//

#import "HookHelpers.h"
#import "Settings/ModernSettingsPageViewController.h"
#import <os/log.h>

static UIFont* _Nonnull remapFont(UIFont* origFont) {
    UIFont* newFont = getDefaultFont(origFont);
    return newFont != nil ? newFont : origFont;
}

// MARK: - NeoFreeBird settings entry

static const void* SettingsEntryKey = &SettingsEntryKey;
static const void* SettingsRootKey = &SettingsRootKey;

static BOOL isSettingsClass(UIViewController* viewController) {
    return [viewController isKindOfClass:objc_getClass("T1GenericSettingsViewController")] ||
           [viewController isKindOfClass:objc_getClass("T1SettingsViewController")];
}

// The generic controller backs the root and every sub-page alike, so the root is
// the first settings-class controller in the navigation stack.
static BOOL settingsVCIsRoot(TFNItemsDataViewController* settingsVC) {
    for (UIViewController* viewController in settingsVC.navigationController.viewControllers) {
        if (viewController == settingsVC) {
            return YES;
        }

        if (isSettingsClass(viewController)) {
            return NO;
        }
    }

    return NO;
}

static BOOL sectionsContainNeoFreeBirdEntry(NSArray* sections) {
    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            continue;
        }

        for (id entry in (NSArray*)section) {
            if (objc_getAssociatedObject(entry, SettingsEntryKey)) {
                return YES;
            }
        }
    }

    return NO;
}

static TFNSettingsNavigationItem* makeNeoFreeBirdSettingsItem(
    TFNItemsDataViewController* settingsVC) {
    Class itemClass = objc_getClass("TFNSettingsNavigationItem");
    SEL initializer =
        @selector(initWithTitle:detail:iconName:controllerFactory:);
    if (!itemClass ||
        ![itemClass instancesRespondToSelector:initializer]) {
        NSLog(@"[NFB] settings item unavailable: class=%@", itemClass);
        return nil;
    }

    UIColor* iconColor;
    if (@available(iOS 12.0, *)) {
        if (settingsVC.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            iconColor = [UIColor systemGray2Color];
        } else {
            iconColor = [UIColor secondaryLabelColor];
        }
    } else {
        iconColor = [UIColor secondaryLabelColor];
    }

    UIImage* twitterIcon = [UIImage tfn_vectorImageNamed:@"twitter"
                                                fitsSize:CGSizeMake(20, 20)
                                               fillColor:iconColor];

    TFNTwitterAccount* account = nil;
    if ([settingsVC respondsToSelector:@selector(account)]) {
        account = ((id (*)(id, SEL))objc_msgSend)(
            settingsVC, @selector(account));
    }
    TFNSettingsNavigationItem* bhtwitter = [[itemClass alloc]
            initWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:@"NFB_SETTINGS_TITLE"]
                   detail:[[BHTBundle sharedBundle] localizedStringForKey:@"NFB_SETTINGS_DETAIL"]
                 iconName:nil
        controllerFactory:^UIViewController* {
            return [BHTManager BHTSettingsWithAccount:account];
        }];

    if (!bhtwitter) return nil;
    if (twitterIcon) {
        @try {
            [bhtwitter setValue:twitterIcon forKey:@"icon"];
        } @catch (__unused NSException* exception) {
        }
    }

    objc_setAssociatedObject(bhtwitter, SettingsEntryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    return bhtwitter;
}

static NSArray* sectionsByInsertingEntry(TFNItemsDataViewController* settingsVC,
                                         NSArray* sections) {
    NSMutableArray* newSections = [sections mutableCopy] ?: [NSMutableArray array];
    TFNSettingsNavigationItem* item =
        makeNeoFreeBirdSettingsItem(settingsVC);
    if (!item) return sections;
    [newSections insertObject:@[item] atIndex:0];
    return newSections;
}

// Async settings fetches rebuild the sections and discard one-shot inserts, and
// root-ness is unknowable during the first build (not yet on the nav stack). So
// tag the root in viewWillAppear, insert once to repair the first build, and let
// the rebuild transform below re-add the entry on every later snapshot.
static void insertNeoFreeBirdSettingsIfRoot(TFNItemsDataViewController* settingsVC) {
    BOOL isRoot = settingsVCIsRoot(settingsVC);
    NSLog(@"[NFB] T1GenericSettings viewWillAppear class=%@ root=%d nav=%@",
          NSStringFromClass([settingsVC class]), isRoot,
          [settingsVC.navigationController.viewControllers valueForKey:@"class"]);

    if (!isRoot) {
        return;
    }

    objc_setAssociatedObject(settingsVC, SettingsRootKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (sectionsContainNeoFreeBirdEntry(settingsVC.sections)) {
        return;
    }

    settingsVC.sections = sectionsByInsertingEntry(settingsVC, settingsVC.sections);
}

static NSArray* sectionsWithNeoFreeBirdEntry(TFNItemsDataViewController* settingsVC,
                                             NSArray* sections) {
    if (!isSettingsClass(settingsVC)) {
        return sections;
    }

    if (![objc_getAssociatedObject(settingsVC, SettingsRootKey) boolValue]) {
        return sections;
    }

    if (sectionsContainNeoFreeBirdEntry(sections)) {
        return sections;
    }

    return sectionsByInsertingEntry(settingsVC, sections);
}

%hook T1GenericSettingsViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    insertNeoFreeBirdSettingsIfRoot(self);
}
%end

// T1SettingsViewController was removed in X 12.24.1.

// Every sections rebuild runs through this transform right before setSections:,
// so hooking it on the base class covers both settings roots.
%hook TFNItemsDataViewController
- (NSArray*)updatedSections:(NSArray*)sections forStyle:(NSInteger)style {
    NSArray* updatedSections = %orig;
    if (isSettingsClass(self)) {
        NSLog(@"[NFB] updatedSections on %@ root-tagged=%d",
              NSStringFromClass([self class]),
              [objc_getAssociatedObject(self, SettingsRootKey) boolValue]);
    }
    return sectionsWithNeoFreeBirdEntry(self, updatedSections);
}
%end

// MARK: - X 12.40.1 diagnostics and fallback entry
//
// X 12.40.1 ships a Swift settings stack (XSettings.SettingsListViewController,
// SettingsChromeViewController, SettingsContainerController, ...) alongside
// T1GenericSettingsViewController. Which class backs the root Settings screen
// is UNCONFIRMED. The log line below prints every settings-like view controller
// that appears so the real root class can be identified (filter Console on NFB).
//
// The fallback adds an "NFB" button to the nav bar of the first Swift settings
// candidate in the stack, since a Swift list is not a TFNItemsDataViewController
// and cannot take the row insertion above. It is best-effort and unverified:
// once the root class is known, replace this with a proper hook and delete the
// logging.

static const void* NFBFallbackButtonKey = &NFBFallbackButtonKey;

static NSArray<NSString*>* swiftSettingsRootCandidates(void) {
    return @[
        @"_TtC9XSettings26SettingsListViewController",
        @"XSettings.SettingsListViewController",
        @"SettingsListViewController",
    ];
}

static BOOL isSwiftSettingsCandidate(UIViewController* viewController) {
    for (NSString* name in swiftSettingsRootCandidates()) {
        Class cls = NSClassFromString(name);
        if (cls && [viewController isKindOfClass:cls]) {
            return YES;
        }
    }
    return NO;
}

static BOOL swiftSettingsVCIsRoot(UIViewController* viewController) {
    for (UIViewController* current in viewController.navigationController.viewControllers) {
        if (current == viewController) {
            return YES;
        }

        if (isSettingsClass(current) || isSwiftSettingsCandidate(current)) {
            return NO;
        }
    }

    return NO;
}

static void addFallbackEntryIfNeeded(UIViewController* viewController) {
    if (!isSwiftSettingsCandidate(viewController)) {
        return;
    }

    if (!swiftSettingsVCIsRoot(viewController)) {
        return;
    }

    if (objc_getAssociatedObject(viewController, NFBFallbackButtonKey)) {
        return;
    }

    UIBarButtonItem* item = [[UIBarButtonItem alloc]
        initWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:@"NFB_SETTINGS_TITLE"]
                style:UIBarButtonItemStylePlain
               target:viewController
               action:NSSelectorFromString(@"nfb_openSettings")];

    NSMutableArray* items =
        [viewController.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    [items addObject:item];
    viewController.navigationItem.rightBarButtonItems = items;

    objc_setAssociatedObject(viewController, NFBFallbackButtonKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[NFB] fallback settings button added to %@", NSStringFromClass([viewController class]));
}

// NSLog redacts dynamic strings as <private> outside a debugger; os_log with
// %{public} keeps them readable in Console.app.
static NSString* NFBSuperchain(Class cls) {
    NSMutableArray* names = [NSMutableArray array];
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        [names addObject:NSStringFromClass(current)];
    }
    return [names componentsJoinedByString:@" > "];
}

// One os_log line per view (a single line is truncated at about 1 KB).
static void NFBLogViewTree(UIView* view, int depth, int* budget) {
    if (!view || depth > 7 || *budget <= 0) {
        return;
    }
    (*budget)--;
    os_log(OS_LOG_DEFAULT, "[NFB] tree depth=%d %{public}@", depth,
           NSStringFromClass([view class]));
    for (UIView* subview in view.subviews) {
        NFBLogViewTree(subview, depth + 1, budget);
    }
}

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;

    NSString* name = NSStringFromClass([self class]);
    if ([name rangeOfString:@"Settings" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        NSMutableArray* stack = [NSMutableArray array];
        for (UIViewController* entry in self.navigationController.viewControllers) {
            [stack addObject:NSStringFromClass([entry class])];
        }
        os_log(OS_LOG_DEFAULT,
               "[NFB] settings-like VC: %{public}@ chain=[%{public}@] parent=%{public}@ "
               "hasSections=%d hasUpdatedSections=%d nav=[%{public}@]",
               name,
               NFBSuperchain([self class]),
               NSStringFromClass([self.parentViewController class]),
               [self respondsToSelector:NSSelectorFromString(@"sections")],
               [self respondsToSelector:NSSelectorFromString(@"updatedSections:forStyle:")],
               [stack componentsJoinedByString:@", "]);
    }

    if (isSwiftSettingsCandidate(self)) {
        NSMutableArray* children = [NSMutableArray array];
        for (UIViewController* child in self.childViewControllers) {
            [children addObject:NSStringFromClass([child class])];
        }
        os_log(OS_LOG_DEFAULT, "[NFB] children=[%{public}@]",
               [children componentsJoinedByString:@", "]);
        int budget = 120;
        NFBLogViewTree(self.view, 0, &budget);
    }

    addFallbackEntryIfNeeded(self);
}

%new
- (void)nfb_openSettings {
    UIViewController* settingsVC = [BHTManager BHTSettingsWithAccount:nil];
    if (settingsVC) {
        [self.navigationController pushViewController:settingsVC animated:YES];
    }
}
%end

// MARK: - Change font

%hook UIFontPickerViewController
- (void)viewWillAppear:(BOOL)arg1 {
    %orig(arg1);
    if (BHTFontTypeForPicker(self).length == 0) {
        return;
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:[[BHTBundle sharedBundle]
                          localizedStringForKey:@"CUSTOM_FONTS_NAVIGATION_BUTTON_TITLE"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(customFontsHandler)];
}
%new
- (void)customFontsHandler {
    if ([[NSFileManager defaultManager]
            fileExistsAtPath:@"/var/mobile/Library/Fonts/AddedFontCache.plist"]) {
        NSAttributedString* AttString = [[NSAttributedString alloc]
            initWithString:[[BHTBundle sharedBundle] localizedStringForKey:@"CUSTOM_FONTS_MENU_TITLE"]
                attributes:@{
                    NSFontAttributeName: [BHTManager menuTitleFont],
                    NSForegroundColorAttributeName: UIColor.labelColor
                }];
        TFNActiveTextItem* title =
            [[%c(TFNActiveTextItem) alloc] initWithTextModel:[[%c(TFNAttributedTextModel) alloc]
                                                                     initWithAttributedString:AttString]
                                                    activeRanges:nil];

        NSMutableArray* actions = [[NSMutableArray alloc] init];
        [actions addObject:title];

        NSDictionary* plistDictionary = [NSPropertyListSerialization
            propertyListWithData:
                [NSData dataWithContentsOfURL:
                            [NSURL fileURLWithPath:@"/var/mobile/Library/Fonts/AddedFontCache.plist"]]
                         options:NSPropertyListImmutable
                          format:NULL
                           error:nil];
        [plistDictionary enumerateKeysAndObjectsUsingBlock:^(id _Nonnull key, id _Nonnull obj,
                                                             BOOL* _Nonnull stop) {
            @try {
                NSString* fontName = ((NSArray*)[obj valueForKey:@"psNames"]).firstObject;
                TFNActionItem* fontAction = [%c(TFNActionItem)
                    actionItemWithTitle:fontName
                                 action:^{
                                     // AddedFontCache supplies PostScript names,
                                     // so persist a concrete face for both
                                     // regular and bold choices. A family-only
                                     // descriptor often cannot be reopened with
                                     // UIFont fontWithName:.
                                     [self setSelectedFontDescriptor:
                                               [UIFontDescriptor
                                                   fontDescriptorWithFontAttributes:@{
                                                       UIFontDescriptorNameAttribute:
                                                           fontName
                                                   }]];
                                     [self.delegate fontPickerViewControllerDidPickFont:self];
                                 }];
                [actions addObject:fontAction];
            } @catch (NSException* exception) {
                NSLog(@"Unable to find installed fonts /n reason: %@", exception.reason);
            }
        }];

        TFNMenuSheetViewController* alert = [[%c(TFNMenuSheetViewController) alloc]
            initWithActionItems:[NSArray arrayWithArray:actions]];
        [alert tfnPresentedCustomPresentFromViewController:self animated:YES completion:nil];
    } else {
        UIAlertController* errAlert = [UIAlertController
            alertControllerWithTitle:@"BHTwitter"
                             message:[[BHTBundle sharedBundle]
                                         localizedStringForKey:@"CUSTOM_FONTS_TUT_ALERT_MESSAGE"]
                      preferredStyle:UIAlertControllerStyleAlert];

        [errAlert
            addAction:
                [UIAlertAction
                    actionWithTitle:[[BHTBundle sharedBundle]
                                        localizedStringForKey:@"INSTALL_IFONT_BUTTON_TITLE"]
                              style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction* _Nonnull action) {
                                [[UIApplication sharedApplication]
                                              openURL:[NSURL
                                                          URLWithString:
                                                              @"https://apps.apple.com/sa/app/"
                                                              @"ifont-find-install-any-font/id1173222289"]
                                              options:@{}
                                    completionHandler:nil];
                            }]];
        [errAlert addAction:[UIAlertAction
                                actionWithTitle:[[BHTBundle sharedBundle]
                                                    localizedTwitterStringForKey:@"OK_ACTION_LABEL"]
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
        [self presentViewController:errAlert animated:true completion:nil];
    }
}
%end

// Every named getter (bodyFont, title1Font, ...) dispatches to one of these five
// methods, the only ones that actually build a UIFont; remapping here covers all.
%hook TFNUIDefaultFontGroup
- (UIFont*)fontOfSize:(CGFloat)size {
    UIFont* origFont = %orig;
    return remapFont(origFont);
}
- (UIFont*)mediumFontOfSize:(CGFloat)size {
    UIFont* origFont = %orig;
    return remapFont(origFont);
}
- (UIFont*)boldFontOfSize:(CGFloat)size {
    UIFont* origFont = %orig;
    return remapFont(origFont);
}
- (UIFont*)heavyFontOfSize:(CGFloat)size {
    UIFont* origFont = %orig;
    return remapFont(origFont);
}
- (UIFont*)monospacedDigitFontOfSize:(CGFloat)size weight:(CGFloat)weight {
    UIFont* origFont = %orig;
    return remapFont(origFont);
}
%end

// X 12.9's newer SwiftUI and timeline surfaces resolve fonts through
// XFontCatalog instead of TFNUIDefaultFontGroup. Remap every public catalog
// output while leaving the original font in place when no valid custom face is
// selected.
%hook XFontCatalog
+ (UIFont*)fontForToken:(NSInteger)token {
    UIFont* origFont = %orig;
    return remapFont(origFont);
}
+ (UIFont*)customFontOfSize:(CGFloat)size
                    weight:(NSInteger)weight
     scalesWithDynamicType:(BOOL)scalesWithDynamicType {
    UIFont* origFont = %orig;
    return remapFont(origFont);
}
+ (UIFont*)spoofingResistantUsernameFontForToken:(NSInteger)token {
    UIFont* origFont = %orig;
    return remapFont(origFont);
}
+ (UIFont*)monospaceFixedFontOfSize:(CGFloat)size {
    UIFont* origFont = %orig;
    return remapFont(origFont);
}
+ (UIFont*)contentFontWithOffset:(CGFloat)offset weight:(NSInteger)weight {
    UIFont* origFont = %orig;
    return remapFont(origFont);
}
+ (UIFont*)tabularDigitsFontOfSize:(CGFloat)size weight:(CGFloat)weight {
    UIFont* origFont = %orig;
    return remapFont(origFont);
}
%end
