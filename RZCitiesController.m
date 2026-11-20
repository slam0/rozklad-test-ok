#import "RZCitiesController.h"
#import "RZStopSearchController.h"
#import "RZLang.h"
#import "RZViews.h"
#import "rz_config.h"

NSString *RZSiteBase(void)
{
    NSString *site = @RZ_SITE_URL;
    if (![site hasPrefix:@"http"]) site = [[NSUserDefaults standardUserDefaults] stringForKey:@"site_base_root"];
    if (![site hasPrefix:@"http"]) return nil;
    if (![site hasSuffix:@"/"]) site = [site stringByAppendingString:@"/"];
    return site;
}

NSData *RZFetch(NSString *urlString, NSUInteger limit, NSString **reason)
{
    /* Klasy sieciowe bierzemy po nazwie w czasie działania (SDK 9.3 i iOS 6 trzymają je w różnych bibliotekach). */
    Class reqClass = NSClassFromString(@"NSMutableURLRequest");
    Class connClass = NSClassFromString(@"NSURLConnection");
    Class httpClass = NSClassFromString(@"NSHTTPURLResponse");
    if (!reqClass || !connClass || !httpClass) {
        *reason = RZL(@"Ten system nie ma potrzebnych funkcji sieciowych.");
        return nil;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    NSString *last = RZL(@"brak odpowiedzi");
    for (int attempt = 0; attempt < 3; attempt++) {
        @autoreleasepool {
            NSMutableURLRequest *rq = [reqClass requestWithURL:url
                                                   cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                               timeoutInterval:45.0];
            NSURLResponse *resp = nil;
            NSError *err = nil;
            NSData *d = [connClass sendSynchronousRequest:rq returningResponse:&resp error:&err];
            NSInteger code = [resp isKindOfClass:httpClass] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
            if (d && code == 200) {
                if ([d length] > limit) {
                    *reason = RZL(@"Plik ze strony jest zbyt duży, więc go odrzuciłem.");
                    return nil;
                }
                return d;
            }
            if (code == 404) {
                *reason = RZL(@"Tych danych nie ma na stronie (błąd 404). Spróbuj za kilka minut, dane mogą się właśnie odświeżać.");
                return nil;
            }
            if (err) {
                if ([[err domain] isEqualToString:@"NSURLErrorDomain"] && [err code] <= -1200 && [err code] >= -1206) {
                    *reason = RZL(@"Telefon nie mógł nawiązać bezpiecznego połączenia (HTTPS). Na iOS 6 potrzebna jest poprawka SSL/TLS z Cydii. Sprawdź też, czy data i godzina w telefonie są poprawne.");
                    return nil;
                }
                last = [err localizedDescription];
            } else if (code) {
                last = [NSString stringWithFormat:RZL(@"błąd serwera %ld"), (long)code];
            }
        }
        [NSThread sleepForTimeInterval:1.5];
    }
    *reason = [NSString stringWithFormat:RZL(@"Nie udało się pobrać danych. Sprawdź połączenie z internetem i spróbuj jeszcze raz.\n\n(%@)"), last];
    return nil;
}

void RZPresentCities(UIViewController *host)
{
    if (!host || host.presentedViewController) return;
    RZCitiesController *c = [[RZCitiesController alloc] initWithStyle:UITableViewStylePlain];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:c];
    RZStyleNavigationBar(nav.navigationBar);
    [host presentViewController:nav animated:YES completion:nil];
}

@implementation RZCitiesController {
    NSArray *_cities;               /* słowniki z miasta.json (w trybie miast: tylko miasta jednego kraju) */
    NSArray *_countries;            /* tryb krajów: nazwy krajów w kolejności z listy */
    NSString *_base;
    UIActivityIndicatorView *_spin;
    UILabel *_msg;
    BOOL _loading;
    BOOL _citiesMode;
}

/* Drugi krok: miasta jednego kraju (dane już pobrane, bez internetu) */
- (id)initWithCities:(NSArray *)cities base:(NSString *)base title:(NSString *)title
{
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _cities = cities;
        _base = [base copy];
        _citiesMode = YES;
        self.title = title;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    RZStyleTable(self.tableView);
    if (_citiesMode) return;

    self.title = RZL(@"Wybierz kraj");
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:RZL(@"Anuluj") style:UIBarButtonItemStyleBordered
                                        target:self action:@selector(cancelTapped)];

    _spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    _spin.center = CGPointMake(self.view.bounds.size.width / 2, 60);
    _spin.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:_spin];

    _msg = [[UILabel alloc] initWithFrame:CGRectMake(20, 90, self.view.bounds.size.width - 40, 160)];
    _msg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _msg.backgroundColor = [UIColor clearColor];
    _msg.textColor = RZSubtleColor();
    _msg.textAlignment = NSTextAlignmentCenter;
    _msg.numberOfLines = 0;
    _msg.font = [UIFont systemFontOfSize:15];
    [self.view addSubview:_msg];

    _base = RZSiteBase();
    if (!_base) {
        _msg.text = RZL(@"Brak adresu strony z danymi. Zbuduj aplikację z wpisanym adresem (rz_config.h).");
        return;
    }
    [self load];
}

- (void)cancelTapped
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)load
{
    if (_loading) return;
    _loading = YES;
    _msg.text = RZL(@"Pobieram listę miast…");
    [_spin startAnimating];
    NSString *url = [_base stringByAppendingString:@"miasta.json"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *why = nil;
        NSArray *list = nil;
        NSData *d = RZFetch(url, 512 * 1024, &why);
        if (d) {
            id root = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
            id c = [root isKindOfClass:[NSDictionary class]] ? [root objectForKey:@"c"] : nil;
            if ([c isKindOfClass:[NSArray class]]) list = c;
            if (!list) why = RZL(@"Lista miast ma zły format.");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            _loading = NO;
            [_spin stopAnimating];
            if (list && [list count]) {
                _cities = list;
                NSMutableArray *k = [NSMutableArray array];
                for (NSDictionary *c in list) {
                    NSString *name = [c objectForKey:@"k"];
                    if (name && ![k containsObject:name]) [k addObject:name];
                }
                _countries = k;
                _msg.text = @"";
                [self.tableView reloadData];
            } else {
                _msg.text = [NSString stringWithFormat:@"%@\n\n%@", RZL(@"Nie udało się pobrać listy miast."), why ? why : @""];
                self.navigationItem.rightBarButtonItem =
                    [[UIBarButtonItem alloc] initWithTitle:RZL(@"Ponów") style:UIBarButtonItemStyleBordered
                                                    target:self action:@selector(retryTapped)];
            }
        });
    });
}

- (void)retryTapped
{
    self.navigationItem.rightBarButtonItem = nil;
    [self load];
}

- (NSArray *)citiesOfCountry:(NSString *)country
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *c in _cities) if ([[c objectForKey:@"k"] isEqualToString:country]) [out addObject:c];
    return out;
}

#pragma mark - Tabela

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s
{
    return _citiesMode ? (NSInteger)[_cities count] : (NSInteger)[_countries count];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"city"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"city"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.textColor = RZCellTextColor();
    cell.detailTextLabel.textColor = RZSubtleColor();
    if (_citiesMode) {
        NSDictionary *c = [_cities objectAtIndex:ip.row];
        cell.textLabel.text = [c objectForKey:@"n"];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ %lu", RZL(@"przystanków:"),
                                     (unsigned long)[[c objectForKey:@"s"] unsignedIntegerValue]];
    } else {
        NSString *k = [_countries objectAtIndex:ip.row];
        cell.textLabel.text = RZL(k);
        NSMutableArray *names = [NSMutableArray array];
        for (NSDictionary *c in [self citiesOfCountry:k]) [names addObject:[c objectForKey:@"n"]];
        cell.detailTextLabel.text = [names componentsJoinedByString:@", "];
    }
    return cell;
}

- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip
{
    RZStyleCell(cell);
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s
{
    return RZSectionHeaderView(_citiesMode ? RZL(@"Wybierz miasto:") : (_countries ? RZL(@"Wybierz kraj:") : @""));
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s
{
    return (_citiesMode || _countries) ? 34.0f : 0.0f;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (!_citiesMode) {
        NSString *k = [_countries objectAtIndex:ip.row];
        NSArray *list = [self citiesOfCountry:k];
        if ([list count] == 1) {            /* jedno miasto w kraju: od razu przystanki */
            [self openCity:[list objectAtIndex:0]];
            return;
        }
        RZCitiesController *c = [[RZCitiesController alloc] initWithCities:list base:_base title:RZL(k)];
        [self.navigationController pushViewController:c animated:YES];
        return;
    }
    [self openCity:[_cities objectAtIndex:ip.row]];
}

- (void)openCity:(NSDictionary *)c
{
    NSString *u = [c objectForKey:@"u"];
    NSString *base = [_base stringByAppendingString:(u ? u : @"")];
    RZStopSearchController *sc = [[RZStopSearchController alloc] initWithCity:c baseURL:base];
    [self.navigationController pushViewController:sc animated:YES];
}

@end
