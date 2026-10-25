@IsTest
private class OrderItemTriggerHandlerTest {
    private static final Decimal PHO_PRICE = 55000;

    @TestSetup
    static void setup() {
        TestDataFactory.createOrderWithTable();
        TestDataFactory.createMenuItem('Phở bò tái', PHO_PRICE, true);
    }

    private static Order_Request__c getOrder() {
        return [SELECT Id FROM Order_Request__c LIMIT 1];
    }

    private static Menu_Item__c getMenuItem() {
        return [SELECT Id FROM Menu_Item__c LIMIT 1];
    }

    @IsTest
    static void insertValidQuantity_calculatesLineSubtotal() {
        Order_Item__c item = TestDataFactory.buildOrderItems(
            getOrder().Id,
            getMenuItem().Id,
            3,
            1
        )[0];

        Test.startTest();
        insert item;
        Test.stopTest();

        Order_Item__c saved = [
            SELECT Line_Subtotal__c
            FROM Order_Item__c
            WHERE Id = :item.Id
        ];
        Assert.areEqual(
            3 * PHO_PRICE,
            saved.Line_Subtotal__c,
            'Line_Subtotal__c should equal Quantity x Price'
        );
    }

    @IsTest
    static void insertWithoutStatus_defaultsToPending() {
        Order_Item__c item = TestDataFactory.buildOrderItems(
            getOrder().Id,
            getMenuItem().Id,
            1,
            1
        )[0];

        Test.startTest();
        insert item;
        Test.stopTest();

        Order_Item__c saved = [
            SELECT Status__c
            FROM Order_Item__c
            WHERE Id = :item.Id
        ];
        Assert.areEqual(
            'Pending',
            saved.Status__c,
            'Empty Status__c should default to Pending'
        );
    }

    @IsTest
    static void beforeInsert_nullStatus_setsPendingInMemory() {
        // Gọi thẳng handler để chắc chắn nhánh Status__c == null được kiểm tra,
        // không phụ thuộc vào giá trị default của picklist trong org
        Order_Item__c item = new Order_Item__c(
            Quantity__c = 1,
            Status__c = null
        );

        OrderItemTriggerHandler.beforeInsert(new List<Order_Item__c>{ item });

        Assert.areEqual(OrderItemTriggerHandler.STATUS_PENDING, item.Status__c);
        Assert.isNull(
            item.Line_Subtotal__c,
            'Line_Subtotal__c should be null when there is no Menu Item'
        );
    }

    @IsTest
    static void insertWithExistingStatus_keepsStatus() {
        Order_Item__c item = TestDataFactory.buildOrderItems(
            getOrder().Id,
            getMenuItem().Id,
            1,
            1
        )[0];
        item.Status__c = 'Accepted';

        Test.startTest();
        insert item;
        Test.stopTest();

        Order_Item__c saved = [
            SELECT Status__c
            FROM Order_Item__c
            WHERE Id = :item.Id
        ];
        Assert.areEqual(
            'Accepted',
            saved.Status__c,
            'Existing Status__c should not be overwritten'
        );
    }

    @IsTest
    static void insertZeroOrNullQuantity_isBlocked() {
        Id orderId = getOrder().Id;
        Id menuItemId = getMenuItem().Id;
        List<Order_Item__c> items = new List<Order_Item__c>{
            TestDataFactory.buildOrderItems(orderId, menuItemId, 0, 1)[0],
            TestDataFactory.buildOrderItems(orderId, menuItemId, null, 1)[0],
            TestDataFactory.buildOrderItems(orderId, menuItemId, -2, 1)[0],
            TestDataFactory.buildOrderItems(orderId, menuItemId, 2, 1)[0]
        };

        Test.startTest();
        List<Database.SaveResult> results = Database.insert(items, false);
        Test.stopTest();

        for (Integer i = 0; i < 3; i++) {
            Assert.isFalse(
                results[i].isSuccess(),
                'Record ' + i + ' with invalid quantity should be blocked'
            );
            Assert.areEqual(
                OrderItemTriggerHandler.ERROR_INVALID_QUANTITY,
                results[i].getErrors()[0].getMessage(),
                'Unexpected error message'
            );
        }
        // addError chỉ chặn record sai, record hợp lệ trong cùng batch vẫn được lưu
        Assert.isTrue(
            results[3].isSuccess(),
            'Valid record should not be blocked'
        );
        Assert.areEqual(1, [SELECT COUNT() FROM Order_Item__c]);
    }

    @IsTest
    static void insertZeroQuantity_throwsDmlExceptionWhenAllOrNone() {
        Order_Item__c item = TestDataFactory.buildOrderItems(
            getOrder().Id,
            getMenuItem().Id,
            0,
            1
        )[0];

        Test.startTest();
        try {
            insert item;
            Assert.fail('Expected DmlException when Quantity__c = 0');
        } catch (DmlException e) {
            Assert.isTrue(
                e.getMessage()
                    .contains(OrderItemTriggerHandler.ERROR_INVALID_QUANTITY)
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void bulkInsert_queryCountDoesNotGrowWithRecordCount() {
        Id orderId = getOrder().Id;
        Menu_Item__c secondMenuItem = TestDataFactory.createMenuItem(
            'Cà phê sữa đá',
            30000,
            true
        );
        List<Order_Item__c> single = TestDataFactory.buildOrderItems(
            orderId,
            getMenuItem().Id,
            1,
            1
        );
        // 200 record trộn 2 món khác nhau, đúng kích thước 1 batch trigger
        List<Order_Item__c> bulkItems = TestDataFactory.buildOrderItems(
            orderId,
            getMenuItem().Id,
            2,
            100
        );
        bulkItems.addAll(
            TestDataFactory.buildOrderItems(orderId, secondMenuItem.Id, 2, 100)
        );

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        insert single;
        Integer singleQueries = Limits.getQueries() - queriesBefore;

        queriesBefore = Limits.getQueries();
        insert bulkItems;
        Integer bulkQueries = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(
            1,
            singleQueries,
            'Trigger should use exactly 1 SOQL query'
        );
        Assert.areEqual(
            singleQueries,
            bulkQueries,
            'SOQL count should not grow with record count'
        );

        for (Order_Item__c saved : [
            SELECT Line_Subtotal__c, Menu_Item__c
            FROM Order_Item__c
            WHERE Id IN :bulkItems
        ]) {
            Decimal expected = saved.Menu_Item__c == secondMenuItem.Id
                ? 2 * 30000
                : 2 * PHO_PRICE;
            Assert.areEqual(expected, saved.Line_Subtotal__c);
        }
    }

    @IsTest
    static void insertMenuItemWithoutPrice_leavesSubtotalEmpty() {
        Menu_Item__c noPrice = TestDataFactory.createMenuItem(
            'Món chưa có giá',
            null,
            true
        );
        Order_Item__c item = TestDataFactory.buildOrderItems(
            getOrder().Id,
            noPrice.Id,
            2,
            1
        )[0];

        Test.startTest();
        insert item;
        Test.stopTest();

        Order_Item__c saved = [
            SELECT Line_Subtotal__c
            FROM Order_Item__c
            WHERE Id = :item.Id
        ];
        Assert.isNull(
            saved.Line_Subtotal__c,
            'Line_Subtotal__c should be null when Menu Item has no price'
        );
    }

    // ===================== BEFORE UPDATE: Status =====================

    /**
     * Insert sẵn mỗi record ở 1 trạng thái. Insert không kiểm tra luồng
     * trạng thái nên dùng được để setup thẳng Served/Canceled...
     */
    private static List<Order_Item__c> insertItemsWithStatus(
        List<String> statuses
    ) {
        Id orderId = getOrder().Id;
        Id menuItemId = getMenuItem().Id;
        List<Order_Item__c> items = new List<Order_Item__c>();
        for (String status : statuses) {
            Order_Item__c item = TestDataFactory.buildOrderItems(
                orderId,
                menuItemId,
                1,
                1
            )[0];
            item.Status__c = status;
            items.add(item);
        }
        insert items;
        return items;
    }

    /** Build bản update chỉ chứa Id + Status__c mới, đúng thứ tự đầu vào. */
    private static List<Order_Item__c> buildStatusUpdates(
        List<Order_Item__c> items,
        List<String> newStatuses
    ) {
        List<Order_Item__c> updates = new List<Order_Item__c>();
        for (Integer i = 0; i < items.size(); i++) {
            updates.add(
                new Order_Item__c(Id = items[i].Id, Status__c = newStatuses[i])
            );
        }
        return updates;
    }

    private static Map<Id, Order_Item__c> querySaved(
        List<Order_Item__c> items
    ) {
        return new Map<Id, Order_Item__c>(
            [
                SELECT Id, Status__c, Accept_Time__c, Ready_Time__c
                FROM Order_Item__c
                WHERE Id IN :items
            ]
        );
    }

    @IsTest
    static void updateValidTransitions_succeed() {
        List<String> fromStatuses = new List<String>{
            'Pending',
            'Pending',
            'Accepted',
            'Accepted',
            'Preparing',
            'Ready'
        };
        List<String> toStatuses = new List<String>{
            'Accepted',
            'Canceled',
            'Preparing',
            'Canceled',
            'Ready',
            'Served'
        };
        List<Order_Item__c> items = insertItemsWithStatus(fromStatuses);

        Test.startTest();
        List<Database.SaveResult> results = Database.update(
            buildStatusUpdates(items, toStatuses),
            false
        );
        Test.stopTest();

        Map<Id, Order_Item__c> saved = querySaved(items);
        for (Integer i = 0; i < items.size(); i++) {
            String transition = fromStatuses[i] + ' -> ' + toStatuses[i];
            Assert.isTrue(
                results[i].isSuccess(),
                transition + ' should be allowed'
            );
            Assert.areEqual(
                toStatuses[i],
                saved.get(items[i].Id).Status__c,
                transition + ' should be saved'
            );
        }
    }

    @IsTest
    static void updateInvalidTransitions_areBlocked() {
        List<String> fromStatuses = new List<String>{
            'Pending',
            'Pending',
            'Pending',
            'Accepted',
            'Preparing',
            'Preparing',
            'Ready',
            'Served',
            'Served',
            'Canceled',
            'Canceled'
        };
        List<String> toStatuses = new List<String>{
            'Preparing', // nhảy cóc
            'Ready', // nhảy cóc
            'Served', // nhảy cóc
            'Ready', // nhảy cóc
            'Accepted', // đi lùi
            'Canceled', // đang nấu thì không hủy
            'Preparing', // đi lùi
            'Pending', // trạng thái cuối
            'Canceled', // trạng thái cuối
            'Pending', // trạng thái cuối
            'Accepted' // trạng thái cuối
        };
        List<Order_Item__c> items = insertItemsWithStatus(fromStatuses);

        Test.startTest();
        List<Database.SaveResult> results = Database.update(
            buildStatusUpdates(items, toStatuses),
            false
        );
        Test.stopTest();

        Map<Id, Order_Item__c> saved = querySaved(items);
        for (Integer i = 0; i < items.size(); i++) {
            String transition = fromStatuses[i] + ' -> ' + toStatuses[i];
            Assert.isFalse(
                results[i].isSuccess(),
                transition + ' should be blocked'
            );
            Assert.areEqual(
                OrderItemTriggerHandler.ERROR_INVALID_STATUS + toStatuses[i],
                results[i].getErrors()[0].getMessage(),
                'Unexpected error message for ' + transition
            );
            Order_Item__c record = saved.get(items[i].Id);
            Assert.areEqual(
                fromStatuses[i],
                record.Status__c,
                transition + ': Status should stay unchanged'
            );
            Assert.isNull(
                record.Accept_Time__c,
                transition + ': Accept_Time__c should not be set'
            );
            Assert.isNull(
                record.Ready_Time__c,
                transition + ': Ready_Time__c should not be set'
            );
        }
    }

    @IsTest
    static void updateStatusToBlank_isBlocked() {
        Order_Item__c item = insertItemsWithStatus(
            new List<String>{ 'Pending' }
        )[0];

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Order_Item__c(Id = item.Id, Status__c = null),
            false
        );
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Blank Status should be blocked');
        Assert.areEqual(
            OrderItemTriggerHandler.ERROR_INVALID_STATUS + '(blank)',
            result.getErrors()[0].getMessage()
        );
    }

    @IsTest
    static void updateInvalidTransition_throwsDmlExceptionWhenAllOrNone() {
        Order_Item__c item = insertItemsWithStatus(
            new List<String>{ 'Served' }
        )[0];

        Test.startTest();
        try {
            update new Order_Item__c(Id = item.Id, Status__c = 'Pending');
            Assert.fail('Expected DmlException when Served -> Pending');
        } catch (DmlException e) {
            Assert.areEqual(
                OrderItemTriggerHandler.ERROR_INVALID_STATUS + 'Pending',
                e.getDmlMessage(0),
                'Unexpected error: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void updatePendingToAccepted_setsAcceptTime() {
        Order_Item__c item = insertItemsWithStatus(
            new List<String>{ 'Pending' }
        )[0];
        // DateTime lưu xuống DB bị cắt mili giây, lùi 1s để so sánh an toàn
        Datetime beforeUpdate = System.now().addSeconds(-1);

        Test.startTest();
        update new Order_Item__c(Id = item.Id, Status__c = 'Accepted');
        Test.stopTest();

        Order_Item__c saved = querySaved(new List<Order_Item__c>{ item })
            .get(item.Id);
        Assert.isNotNull(saved.Accept_Time__c, 'Accept_Time__c should be set');
        Assert.isTrue(
            saved.Accept_Time__c >= beforeUpdate &&
                saved.Accept_Time__c <= System.now(),
            'Accept_Time__c should be the time of the update'
        );
        Assert.isNull(
            saved.Ready_Time__c,
            'Ready_Time__c should not be set when Accepted'
        );
    }

    @IsTest
    static void updatePreparingToReady_setsReadyTime() {
        Order_Item__c item = insertItemsWithStatus(
            new List<String>{ 'Preparing' }
        )[0];
        Datetime beforeUpdate = System.now().addSeconds(-1);

        Test.startTest();
        update new Order_Item__c(Id = item.Id, Status__c = 'Ready');
        Test.stopTest();

        Order_Item__c saved = querySaved(new List<Order_Item__c>{ item })
            .get(item.Id);
        Assert.isNotNull(saved.Ready_Time__c, 'Ready_Time__c should be set');
        Assert.isTrue(
            saved.Ready_Time__c >= beforeUpdate &&
                saved.Ready_Time__c <= System.now(),
            'Ready_Time__c should be the time of the update'
        );
        Assert.isNull(
            saved.Accept_Time__c,
            'Accept_Time__c should not be set when Ready'
        );
    }

    @IsTest
    static void updateOtherTransitions_keepExistingTimes() {
        Datetime fixedTime = Datetime.newInstance(2026, 1, 1, 8, 0, 0);
        Order_Item__c item = insertItemsWithStatus(
            new List<String>{ 'Accepted' }
        )[0];
        update new Order_Item__c(Id = item.Id, Accept_Time__c = fixedTime);

        Test.startTest();
        update new Order_Item__c(Id = item.Id, Status__c = 'Preparing');
        Test.stopTest();

        Order_Item__c saved = querySaved(new List<Order_Item__c>{ item })
            .get(item.Id);
        Assert.areEqual(
            fixedTime,
            saved.Accept_Time__c,
            'Accepted -> Preparing should not touch Accept_Time__c'
        );
        Assert.isNull(
            saved.Ready_Time__c,
            'Accepted -> Preparing should not set Ready_Time__c'
        );
    }

    @IsTest
    static void updateWithoutStatusChange_keepsTimes() {
        Datetime acceptTime = Datetime.newInstance(2026, 1, 1, 8, 0, 0);
        Datetime readyTime = Datetime.newInstance(2026, 1, 1, 8, 15, 0);
        List<Order_Item__c> items = insertItemsWithStatus(
            new List<String>{ 'Accepted', 'Ready' }
        );

        Test.startTest();
        // Status giữ nguyên, chỉ đổi field khác => không được ghi lại thời gian
        update new List<Order_Item__c>{
            new Order_Item__c(
                Id = items[0].Id,
                Accept_Time__c = acceptTime,
                Special_Instructions__c = 'Ít cay'
            ),
            new Order_Item__c(
                Id = items[1].Id,
                Ready_Time__c = readyTime,
                Special_Instructions__c = 'Không hành'
            )
        };
        Test.stopTest();

        Map<Id, Order_Item__c> saved = querySaved(items);
        Assert.areEqual(
            acceptTime,
            saved.get(items[0].Id).Accept_Time__c,
            'Accept_Time__c should not be overwritten'
        );
        Assert.areEqual(
            readyTime,
            saved.get(items[1].Id).Ready_Time__c,
            'Ready_Time__c should not be overwritten'
        );
    }

    @IsTest
    static void bulkUpdate_partialSuccessWithoutSoql() {
        List<String> pendingStatuses = new List<String>();
        for (Integer i = 0; i < 200; i++) {
            pendingStatuses.add('Pending');
        }
        List<Order_Item__c> items = insertItemsWithStatus(pendingStatuses);

        // 100 record đầu chuyển hợp lệ, 100 record sau nhảy cóc sang Ready
        List<String> newStatuses = new List<String>();
        for (Integer i = 0; i < 200; i++) {
            newStatuses.add(i < 100 ? 'Accepted' : 'Ready');
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<Database.SaveResult> results = Database.update(
            buildStatusUpdates(items, newStatuses),
            false
        );
        Integer updateQueries = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(
            0,
            updateQueries,
            'Status validation should not use SOQL'
        );
        for (Integer i = 0; i < 200; i++) {
            Assert.areEqual(
                i < 100,
                results[i].isSuccess(),
                'Unexpected result for record ' + i
            );
        }
        Assert.areEqual(
            100,
            [
                SELECT COUNT()
                FROM Order_Item__c
                WHERE Status__c = 'Accepted' AND Accept_Time__c != NULL
            ]
        );
        Assert.areEqual(
            100,
            [SELECT COUNT() FROM Order_Item__c WHERE Status__c = 'Pending']
        );
    }
}
