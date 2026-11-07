import { LightningElement, api, wire } from "lwc";
import getMenuItems from "@salesforce/apex/MenuController.getMenuItems";
import getCategoryOptions from "@salesforce/apex/MenuController.getCategoryOptions";
import FOOD_IMAGES from "@salesforce/resourceUrl/FoodImages";

const FOLDER = "food-images";
const SEARCH_DELAY_MS = 300;

// Chuẩn hóa chuỗi để so sánh: chữ thường, bỏ dấu tiếng Việt, bỏ khoảng trắng đầu/cuối
function normalizeText(value) {
  return (value || "")
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/đ/g, "d")
    .trim();
}

export default class MenuPageComponent extends LightningElement {
  @api title;
  @api item; // Menu_Item__c record
  categoryOptions = [];
  selectedCategory = "All";
  allMenuItems = [];
  searchKey = ""; // từ khóa đã chuẩn hóa
  searchTimeout;
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

  // 4) Lọc theo category đang chọn VÀ từ khóa tìm kiếm (theo Name)
  get filteredItems() {
    const items = this.allMenuItems.filter((i) => {
      const matchCategory =
        this.selectedCategory === "All" ||
        i.Category__c === this.selectedCategory;
      const matchSearch =
        !this.searchKey || normalizeText(i.Name).includes(this.searchKey);
      return matchCategory && matchSearch;
    });

    return items.map((i) => ({
      ...i,
      imageSrc: i.Image_URL__c
        ? `${FOOD_IMAGES}/${FOLDER}/${i.Image_URL__c}`
        : undefined
    }));
  }

  get hasNoResults() {
    return this.allMenuItems.length > 0 && this.filteredItems.length === 0;
  }

  handleCategoryClick(event) {
    this.selectedCategory = event.currentTarget.dataset.value;
  }

  // Debounce: chỉ lọc sau khi người dùng ngừng gõ SEARCH_DELAY_MS
  handleSearchChange(event) {
    const value = event.target.value;
    clearTimeout(this.searchTimeout);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.searchTimeout = setTimeout(() => {
      this.searchKey = normalizeText(value);
    }, SEARCH_DELAY_MS);
  }

  disconnectedCallback() {
    clearTimeout(this.searchTimeout);
  }
}
