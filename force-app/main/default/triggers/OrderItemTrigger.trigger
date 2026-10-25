/**
 * Trigger duy nhất cho Order_Item__c (one trigger per object).
 * Chỉ dispatch sang Handler, không chứa logic nghiệp vụ.
 */
trigger OrderItemTrigger on Order_Item__c(before insert, before update) {
    if (Trigger.isBefore && Trigger.isInsert) {
        OrderItemTriggerHandler.beforeInsert(Trigger.new);
    }

    if (Trigger.isBefore && Trigger.isUpdate) {
        OrderItemTriggerHandler.beforeUpdate(Trigger.new, Trigger.oldMap);
    }
}
