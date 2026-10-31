public with sharing class OrderService {
  public class OrderItemWrapper {
    @AuraEnabled
    public Id menuItemId;
    @AuraEnabled
    public Decimal quantity;
    @AuraEnabled
    public String specialInstructions;
  }

  @AuraEnabled
  public static void placeOrder(Id tableId, List<OrderItemWrapper> orderItems) {
    /**
     * Tập hợp ID các món ăn trong menu được gọi
     * Kiểm tra xem có món không khả thi không, nếu có dừng việc gọi món
     */

    Set<Id> menuItemIds = new Set<Id>();
    for (OrderItemWrapper orderItem : orderItems) {
      menuItemIds.add(orderItem.menuItemId);
    }

    Map<Id, Menu_Item__c> menuById = new Map<Id, Menu_Item__c>(
      [
        SELECT Id, Name, Price__c, Is_Available__c
        FROM Menu_Item__c
        WHERE Id IN :menuItemIds
      ]
    );

    for (OrderItemWrapper orderItem : orderItems) {
      Menu_Item__c menuItem = menuById.get(orderItem.menuItemId);
      if (menuItem == null || !menuItem.Is_Available__c) {
        throw new AuraHandledException(
          'Món "' +
            (menuItem != null ? menuItem.Name : orderItem.menuItemId) +
            '" hiện đã hết, vui lòng bỏ khỏi giỏ và gửi lại đơn.'
        );
      }
    }

    /**
     * Thực hiện tạo Order_Request__c với Status__c = 'Placed'
     * Tạo danh sách các Order_Item__c dựa trên các món được đặt
     */

    Order_Request__c newOrderRequest = new Order_Request__c(
      Table__c = tableId,
      Status__c = 'Placed',
      Order_Time__c = System.now()
    );
    insert newOrderRequest;

    List<Order_Item__c> newOrderedItems = new List<Order_Item__c>();
    for (OrderItemWrapper orderItem : orderItems) {
      newOrderedItems.add(
        new Order_Item__c(
          Order__c = newOrderRequest.Id,
          Menu_Item__c = orderItem.menuItemId,
          Quantity__c = orderItem.quantity,
          Special_Instructions__c = orderItem.specialInstructions,
          Status__c = 'Pending'
        )
      );
    }

    insert newOrderedItems;
  }
}
