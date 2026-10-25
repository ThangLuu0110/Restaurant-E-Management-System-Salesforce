import { LightningElement, api, wire } from "lwc";
import { getObjectInfo, getPicklistValues } from "lightning/uiObjectInfoApi";
import MENU_ITEM_OBJECT from "@salesforce/schema/Menu_Item__c";
import CATEGORY_FIELD from "@salesforce/schema/Menu_Item__c.Category__c";
import getMenuItems from "@salesforce/apex/MenuController.getMenuItems";
export default class MenuPageComponent extends LightningElement {
  @api title;
  categoryOptions = [];
  selectedCategory = "All";
  menuItems = [];
  error;

  // 1) Lấy defaultRecordTypeId, vì getPicklistValues bắt buộc có recordTypeId
  @wire(getObjectInfo, { objectApiName: MENU_ITEM_OBJECT })
  objectInfo;

  // 2) Lấy giá trị picklist theo record type đó
  @wire(getPicklistValues, {
    recordTypeId: "$objectInfo.data.defaultRecordTypeId",
    fieldApiName: CATEGORY_FIELD
  })
  wiredPicklist({ data, error }) {
    if (data) {
      // data.values: [{ label, value, attributes, validFor }]
      this.categoryOptions = [
        { label: "All", value: "All" },
        ...data.values.map((v) => ({ label: v.label, value: v.value }))
      ];
    } else if (error) {
      console.error(error);
    }
  }

  //3) Tạo dữ liệu hiển thị cho từng chip từ categoryOptions
  get categoryChips() {
    return this.categoryOptions.map((option) => {
      const isActive = option.value === this.selectedCategory;
      return {
        ...option,
        className: isActive ? "chip chip--active" : "chip",
        ariaPressed: isActive ? "true" : "false"
      };
    });
  }

  //4) Lấy dữ liệu hiển thị dựa trên category được chọn
  @wire(getMenuItems, { category: "$selectedCategory" })
  menuItemsWire(result) {
    if (result.data) {
      this.menuItems = result.data;
    } else if (result.error) {
      this.menuItems = [];
      this.error = result.error;
    }
  }

  handleCategoryClick(event) {
    this.selectedCategory = event.currentTarget.dataset.value;

    // sau này: lọc danh sách món theo this.selectedCategory
  }
}
