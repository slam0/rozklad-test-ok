#import <UIKit/UIKit.h>

/* Adres strony z danymi (z rz_config.h albo zapamiętany przy poprzednim pobraniu); nil, gdy nieznany. Kończy się na "/". */
NSString *RZSiteBase(void);

/* Pobiera plik z internetu (3 próby). Wołać w tle, nie w głównym wątku.
   Przy błędzie zwraca nil i opis po polsku w *reason (już przetłumaczony). */
NSData *RZFetch(NSString *url, NSUInteger limit, NSString **reason);

/* Pierwszy ekran: kraje, drugi: miasta kraju (dane z miasta.json). Wyświetlać w UINavigationController. */
@interface RZCitiesController : UITableViewController
- (id)initWithCities:(NSArray *)cities base:(NSString *)base title:(NSString *)title;
@end

/* Otwiera wybór miasta i przystanków (okno z paskiem nawigacji) nad podanym kontrolerem. */
void RZPresentCities(UIViewController *host);
