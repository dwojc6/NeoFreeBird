//
//  Settings.x
//  NeoFreeBird
//

#import "HookHelpers.h"
#import "Settings/ModernSettingsPageViewController.h"

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
    if (!settingsVCIsRoot(settingsVC)) {
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
    return sectionsWithNeoFreeBirdEntry(self, updatedSections);
}
%end

// MARK: - X 12.40.1 settings entry (UIKit list)
//
// In X 12.40.1 the root Settings screen is XSettings.SettingsListViewController.
// It is a TFNViewController (not a TFNItemsDataViewController), so the section
// insertion above no longer applies. Its content is a UITableView of
// XDesignSystem.ListRow cells, so the NeoFreeBird row is added as the table's
// tableHeaderView. That avoids touching X's data source, whose index paths would
// all shift if a real row were inserted. If no table is found, or X already uses
// a header, a nav-bar button is added instead.

// 0: add the NeoFreeBird row to the list (nav-bar button only as a fallback).
// 1: always use the nav-bar button instead of the list row.
#define NFB_PREFER_NAV_BAR_BUTTON 0

static const void* NFBFallbackButtonKey = &NFBFallbackButtonKey;

@interface NFBSettingsHeaderRow : UIControl
@property(nonatomic, weak) UIViewController* owner;
@end

@implementation NFBSettingsHeaderRow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }

    self.backgroundColor = UIColor.clearColor;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel* titleLabel = [UILabel new];
    titleLabel.text = [[BHTBundle sharedBundle] localizedStringForKey:@"NFB_SETTINGS_TITLE"];
    titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightMedium];
    titleLabel.textColor = UIColor.labelColor;

    UILabel* detailLabel = [UILabel new];
    detailLabel.text = [[BHTBundle sharedBundle] localizedStringForKey:@"NFB_SETTINGS_DETAIL"];
    detailLabel.font = [UIFont systemFontOfSize:13.0];
    detailLabel.textColor = UIColor.secondaryLabelColor;
    detailLabel.numberOfLines = 2;

    UIStackView* textStack =
        [[UIStackView alloc] initWithArrangedSubviews:@[ titleLabel, detailLabel ]];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2.0;
    textStack.userInteractionEnabled = NO;
    textStack.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView* chevron =
        [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor = UIColor.tertiaryLabelColor;
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    chevron.userInteractionEnabled = NO;
    chevron.translatesAutoresizingMaskIntoConstraints = NO;

    UIView* separator = [UIView new];
    separator.backgroundColor = UIColor.separatorColor;
    separator.userInteractionEnabled = NO;
    separator.translatesAutoresizingMaskIntoConstraints = NO;

    [self addSubview:textStack];
    [self addSubview:chevron];
    [self addSubview:separator];

    CGFloat hairline = 1.0 / UIScreen.mainScreen.scale;
    [NSLayoutConstraint activateConstraints:@[
        [textStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16.0],
        [textStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor
                                                           constant:-12.0],
        [chevron.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16.0],
        [chevron.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:12.0],
        [separator.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16.0],
        [separator.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [separator.heightAnchor constraintEqualToConstant:hairline],
    ]];

    [self addTarget:self
                  action:@selector(nfb_didTap)
        forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? UIColor.systemFillColor : UIColor.clearColor;
}

- (void)nfb_didTap {
    UIViewController* owner = self.owner;
    if (!owner) {
        return;
    }

    id account = nil;
    if ([owner respondsToSelector:@selector(account)]) {
        account = ((id (*)(id, SEL))objc_msgSend)(owner, @selector(account));
    }

    UIViewController* settingsVC = [BHTManager BHTSettingsWithAccount:account];
    if (settingsVC) {
        [owner.navigationController pushViewController:settingsVC animated:YES];
    }
}

@end

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

static UITableView* NFBFindTableView(UIView* root) {
    if ([root isKindOfClass:[UITableView class]]) {
        return (UITableView*)root;
    }

    for (UIView* subview in root.subviews) {
        UITableView* found = NFBFindTableView(subview);
        if (found) {
            return found;
        }
    }

    return nil;
}

// Returns YES when the header row is (or already was) installed.
static BOOL NFBInstallSettingsHeader(UIViewController* viewController) {
    if (!viewController.isViewLoaded) {
        return NO;
    }

    UITableView* table = NFBFindTableView(viewController.view);
    if (!table) {
        return NO;
    }

    if ([table.tableHeaderView isKindOfClass:[NFBSettingsHeaderRow class]]) {
        return YES;
    }

    // Never replace a header X put there itself.
    if (table.tableHeaderView) {
        return NO;
    }

    NFBSettingsHeaderRow* row = [[NFBSettingsHeaderRow alloc]
        initWithFrame:CGRectMake(0, 0, CGRectGetWidth(table.bounds), 64.0)];
    row.owner = viewController;
    table.tableHeaderView = row;
    return YES;
}

static void addFallbackEntryIfNeeded(UIViewController* viewController) {
    if (!isSwiftSettingsCandidate(viewController)) {
        return;
    }

    if (!swiftSettingsVCIsRoot(viewController)) {
        return;
    }

#if !NFB_PREFER_NAV_BAR_BUTTON
    if (NFBInstallSettingsHeader(viewController)) {
        return;
    }
#endif

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
}

%hook UIViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    addFallbackEntryIfNeeded(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    // Idempotent: re-adds the row if X rebuilt the table or swapped its header.
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
