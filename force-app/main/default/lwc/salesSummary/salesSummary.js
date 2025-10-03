import { LightningElement, track } from 'lwc';
import getMonthlyTotals from '@salesforce/apex/SalesSummaryController.getMonthlyTotals';
import getActiveUsers from '@salesforce/apex/SalesSummaryController.getActiveUsers';
import USER_ID from '@salesforce/user/Id';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class SalesSummary extends LightningElement {
    @track userOptions = [];
    selectedUserId = null;
    rows = [];
    queriedOnce = false;
    isLoading = false;

    columns = [
        { label: 'Month', fieldName: 'monthLabel', type: 'text' },
        {
            label: 'Amount',
            fieldName: 'amountDisplay',
            type: 'text',
            cellAttributes: { class: { fieldName: 'amountClass' } }
        }
    ];

    async connectedCallback() {
        try {
            const opts = await getActiveUsers();
            this.userOptions = opts || [];
            const hasCurrent = this.userOptions.some(o => o.value === USER_ID);
            this.selectedUserId = hasCurrent ? USER_ID : (this.userOptions[0]?.value ?? null);
        } catch (e) {
            this.toast('Error', this.errMsg(e, 'Failed to load users.'), 'error');
        }
    }

    // disable actions when no user selected OR while loading
    get isLoadDisabled() {
        return !this.selectedUserId;
    }
    get actionDisabled() {
        return this.isLoading || this.isLoadDisabled;
    }

    get hasTable() {
        return !this.isLoading && this.rows.length > 0;
    }
    get showInlineNoData() {
        return !this.isLoading && this.queriedOnce && !this.hasTable;
    }

    handleRepChange(event) {
        this.selectedUserId = event.detail.value;
        this.rows = [];
        this.queriedOnce = false;
    }

    async handleLoadClick() {
        await this.loadData();
    }
    async handleRefreshClick() {
        await this.loadData();
    }

    async loadData() {
        if (!this.selectedUserId) return;

        this.rows = [];
        this.isLoading = true;
        try {
            const result = await getMonthlyTotals({ salesRepId: this.selectedUserId });
            const points = (result && result.points) ? result.points : [];
            this.queriedOnce = true;

            if (!points.length) {
                this.toast('No Data', 'No sales found for the selected sales rep.', 'warning');
                return;
            }

            const tableRows = points.map(p => {
                const isZero = !p.total || Number(p.total) === 0;
                return {
                    monthLabel: this.formatMonth(p.year, p.month),
                    amountDisplay: this.formatCurrency(p.total),
                    amountClass: isZero ? 'slds-text-color_error slds-text-title_bold' : ''
                };
            });

            const anyNonZero = tableRows.some(r => !r.amountClass);
            if (!anyNonZero) {
                this.toast('No Data', 'No sales found for the selected sales rep.', 'warning');
                this.rows = [];
                return;
            }

            this.rows = tableRows;
        } catch (e) {
            this.queriedOnce = true;
            this.toast('Error', this.errMsg(e, 'Failed to load data.'), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    formatMonth(year, monthNum) {
        const m = monthNum < 10 ? `0${monthNum}` : `${monthNum}`;
        return `${year}-${m}`;
    }
    formatCurrency(amount) {
        try {
            return new Intl.NumberFormat(undefined, { style: 'currency', currency: 'USD' }).format(amount || 0);
        } catch {
            return `${amount}`;
        }
    }
    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    errMsg(e, fallback) {
        return e && e.body && e.body.message ? e.body.message : fallback;
    }
}
