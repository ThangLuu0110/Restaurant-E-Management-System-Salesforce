import { LightningElement, api, wire } from 'lwc';
import getMenuItems from '@salesforce/apex/MenuController.getMenuItems';

const CATEGORIES = ['All', 'Appetizer', 'Main Course', 'Dessert', 'Beverage'];

export default class MenuPage extends LightningElement {
    @api restaurantName;
    @api title;
    selectedCategory = null;
    items = [];
    error;

    // Key 'category' phải trùng CHÍNH XÁC tên tham số Apex,
    // sai 1 ký tự là nhận null âm thầm, không báo lỗi.
    @wire(getMenuItems)
    wiredItems({ data, error }) {
        if (data) {
            this.items = data.map(i => ({
                ...i,
                priceLabel: new Intl.NumberFormat('vi-VN', {
                    style: 'currency', currency: 'VND'
                }).format(i.Price__c),
                tags: i.Dietary_Tags__c ? i.Dietary_Tags__c.split(';') : []
            }));
            this.error = undefined;
        } else if (error) {
            this.error = error.body?.message ?? 'Không tải được thực đơn';
            this.items = [];
        }
    }

    get categoryOptions() {
        return CATEGORIES.map(c => ({ label: c, value: c }));
    }

    handleCategoryChange(e) {
        const v = e.detail.value;
        this.selectedCategory = v === 'All' ? null : v;
    }
}