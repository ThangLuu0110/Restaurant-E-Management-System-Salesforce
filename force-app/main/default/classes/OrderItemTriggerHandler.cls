/**
 * Handler cho OrderItemTrigger. Xử lý context before insert và before update.
 */
public with sharing class OrderItemTriggerHandler {
    @TestVisible
    private static final String STATUS_PENDING = 'Pending';
    @TestVisible
    private static final String STATUS_ACCEPTED = 'Accepted';
    @TestVisible
    private static final String STATUS_PREPARING = 'Preparing';
    @TestVisible
    private static final String STATUS_READY = 'Ready';
    @TestVisible
    private static final String STATUS_SERVED = 'Served';
    @TestVisible
    private static final String STATUS_CANCELED = 'Canceled';

    @TestVisible
    private static final String ERROR_INVALID_QUANTITY = 'Quantity must be greater than 0.';
    @TestVisible
    private static final String ERROR_INVALID_STATUS = 'Unable to change the status to ';

    /** Trạng thái hiện tại => các trạng thái được phép chuyển sang. */
    @TestVisible
    private static final Map<String, Set<String>> VALID_TRANSITIONS = new Map<String, Set<String>>{
        STATUS_PENDING => new Set<String>{ STATUS_ACCEPTED, STATUS_CANCELED },
        STATUS_ACCEPTED => new Set<String>{ STATUS_PREPARING, STATUS_CANCELED },
        STATUS_PREPARING => new Set<String>{ STATUS_READY },
        STATUS_READY => new Set<String>{ STATUS_SERVED },
        // Served và Canceled là trạng thái cuối, không đổi được nữa
        STATUS_SERVED => new Set<String>(),
        STATUS_CANCELED => new Set<String>()
    };

    public static void beforeInsert(List<Order_Item__c> newItems) {
        List<Order_Item__c> validItems = validateQuantity(newItems);
        setDefaultStatus(newItems);
        calculateLineSubtotal(validItems);
    }

    public static void beforeUpdate(
        List<Order_Item__c> newItems,
        Map<Id, Order_Item__c> oldMap
    ) {
        handleStatusChange(newItems, oldMap);
    }

    /**
     * a. Quantity__c phải > 0. Record sai chỉ bị addError riêng,
     *    các record khác trong cùng batch vẫn được xử lý tiếp.
     *    Trả về danh sách record hợp lệ để tính tiền.
     */
    private static List<Order_Item__c> validateQuantity(
        List<Order_Item__c> items
    ) {
        List<Order_Item__c> validItems = new List<Order_Item__c>();
        for (Order_Item__c item : items) {
            if (item.Quantity__c == null || item.Quantity__c <= 0) {
                item.Quantity__c.addError(ERROR_INVALID_QUANTITY);
            } else {
                validItems.add(item);
            }
        }
        return validItems;
    }

    /** b. Status__c trống thì mặc định là 'Pending'. */
    private static void setDefaultStatus(List<Order_Item__c> items) {
        for (Order_Item__c item : items) {
            if (item.Status__c == null) {
                item.Status__c = STATUS_PENDING;
            }
        }
    }

    /**
     * c. Line_Subtotal__c = Quantity__c * Menu_Item__c.Price__c.
     *    Bulk-safe: gom Id vào Set, query giá đúng 1 lần, tra cứu qua Map.
     */
    private static void calculateLineSubtotal(List<Order_Item__c> items) {
        Set<Id> menuItemIds = new Set<Id>();
        for (Order_Item__c item : items) {
            if (item.Menu_Item__c != null) {
                menuItemIds.add(item.Menu_Item__c);
            }
        }
        // Không có Menu Item nào thì bỏ qua, khỏi tốn 1 SOQL
        if (menuItemIds.isEmpty()) {
            return;
        }

        // Query duy nhất, nằm ngoài mọi vòng lặp
        Map<Id, Decimal> priceByMenuItemId = new Map<Id, Decimal>();
        for (Menu_Item__c menuItem : [
            SELECT Id, Price__c
            FROM Menu_Item__c
            WHERE Id IN :menuItemIds
        ]) {
            priceByMenuItemId.put(menuItem.Id, menuItem.Price__c);
        }

        for (Order_Item__c item : items) {
            Decimal price = priceByMenuItemId.get(item.Menu_Item__c);
            // Thiếu Menu Item hoặc chưa có giá thì để trống, không gán 0 gây hiểu nhầm
            item.Line_Subtotal__c = (price == null)
                ? null
                : item.Quantity__c * price;
        }
    }

    /**
     * d. Chỉ xử lý record có Status__c thay đổi:
     *    1. Chặn chuyển trạng thái không nằm trong VALID_TRANSITIONS.
     *    2. Chuyển sang Accepted thì ghi Accept_Time__c.
     *    3. Chuyển sang Ready thì ghi Ready_Time__c.
     *    Update field khác (không đổi Status) thì không đụng tới thời gian.
     */
    private static void handleStatusChange(
        List<Order_Item__c> newItems,
        Map<Id, Order_Item__c> oldMap
    ) {
        for (Order_Item__c orderItem : newItems) {
            Order_Item__c oldItem = oldMap.get(orderItem.Id);
            if (orderItem.Status__c == oldItem.Status__c) {
                continue;
            }

            Set<String> allowedStatuses = VALID_TRANSITIONS.get(
                oldItem.Status__c
            );
            if (
                allowedStatuses == null ||
                !allowedStatuses.contains(orderItem.Status__c)
            ) {
                String target = (orderItem.Status__c == null)
                    ? '(blank)'
                    : orderItem.Status__c;
                orderItem.Status__c.addError(ERROR_INVALID_STATUS + target);
                continue;
            }

            if (orderItem.Status__c == STATUS_ACCEPTED) {
                orderItem.Accept_Time__c = System.now();
            } else if (orderItem.Status__c == STATUS_READY) {
                orderItem.Ready_Time__c = System.now();
            }
        }
    }
}
