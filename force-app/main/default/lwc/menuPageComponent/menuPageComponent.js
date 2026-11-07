import { LightningElement, api, wire } from "lwc";
import getMenuItems from "@salesforce/apex/MenuController.getMenuItems";
import getCategoryOptions from "@salesforce/apex/MenuController.getCategoryOptions";
import FOOD_IMAGES from "@salesforce/resourceUrl/FoodImages";

const FOLDER = "food-images";
export default class MenuPageComponent extends LightningElement {
  @api title;
  @api item; // Menu_Item__c record
  categoryOptions = [];
  selectedCategory = "All";
  allMenuItems = [];
  error;

  // 1) Lấy giá trị picklist Category__c từ Apex (MenuController.getCategoryOptions)
  @wire(getCategoryOptions)
  wiredCategoryOptions({ data, error }) {
    if (data) {
      // data: ["Appertizer", "Main Course", ...] (API value của picklist)
      this.categoryOptions = [
        { label: "All", value: "All" },
        ...data.map((value) => ({ label: value, value }))
      ];
    } else if (error) {
      this.categoryOptions = [];
      console.error("Không lấy được danh sách category", error);
    }
  }

  //2) Tạo dữ liệu hiển thị cho từng chip từ categoryOptions
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

  //3) Lấy dữ liệu hiển thị dựa trên category được chọn
  @wire(getMenuItems)
  menuItemsWire(result) {
    if (result.data) {
      this.allMenuItems = result.data;
    } else if (result.error) {
      this.allMenuItems = [];
      this.error = result.error;
    }
  }

  get filteredItems() {
    const items =
      this.selectedCategory === "All"
        ? this.allMenuItems
        : this.allMenuItems.filter(
            (i) => i.Category__c === this.selectedCategory
          );

    return items.map((i) => ({
      ...i,
      imageSrc: i.Image_URL__c
        ? `${FOOD_IMAGES}/${FOLDER}/${i.Image_URL__c}`
        : undefined
    }));
  }

  handleCategoryClick(event) {
    this.selectedCategory = event.currentTarget.dataset.value;
  }
}
