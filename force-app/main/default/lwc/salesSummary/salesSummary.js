import { LightningElement, track } from 'lwc';
import getMonthlyTotals from '@salesforce/apex/SalesSummaryController.getMonthlyTotals';
import getActiveUsers from '@salesforce/apex/SalesSummaryController.getActiveUsers';
import USER_ID from '@salesforce/user/Id';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class SalesSummary extends LightningElement {
    // combobox options [{label, value}]
    @track userOptions = [];
    selectedUserId = null;      // default set after we load users
    rows = [];
    queriedOnce = false;        // gate to prevent auto-messages before user action

    columns = [
        { label: 'Month', fieldName: 'monthLabel', type: 'text' },
        {
            label: 'Amount',
            fieldName: 'amountDisplay',
            type: 'text',
            cellAttributes: { class: { fieldName: 'amountClass' } }
        }
    ];

    // --- lifecycle ---
    async connectedCallback() {
        try {
            const opts = await getActiveUsers();
            this.userOptions = opts || [];
            // Preselect current user if present in options
            const hasCurrent = this.userOptions.some(o => o.value === USER_ID);
            this.selectedUserId = hasCurrent ? USER_ID : (this.userOptions[0]?.value ?? null);
            // Do NOT auto-load data: wait for user to click "Show Summary"
        } catch (e) {
            this.toast('Error', this.errMsg(e, 'Failed to load users.'), 'error');
        }
    }

    // --- getters for UI state ---
    get isLoadDisabled() {
        return !this.selectedUserId;
    }
    get hasTable() {
        return this.rows.length > 0;
    }
    get showInlineNoData() {
        // Show the inline red text only after the first explicit query
        return this.queriedOnce && !this.hasTable;
    }

    // --- handlers ---
    handleRepChange(event) {
        this.selectedUserId = event.detail.value;
    
        // reset UI state so previous "no data" message/table vanish
        this.rows = [];
        this.queriedOnce = false;   // hides the inline red message
    }
    

    async handleLoadClick() {
        await this.loadData();
    }

    // --- logic ---
    async loadData() {
        if (!this.selectedUserId) return;

        this.rows = [];
        try {
            const result = await getMonthlyTotals({ salesRepId: this.selectedUserId });
            this.queriedOnce = true;

            const points = (result && result.points) ? result.points : [];
            if (!points.length) {
                // No points at all for the last 12 months → toast + inline message via queriedOnce flag
                this.toast('No Data', 'No sales found for the selected sales rep.', 'warning');
                return;
            }

            // Transform for table (mark zeros red)
            const tableRows = points.map(p => {
                const isZero = !p.total || Number(p.total) === 0;
                return {
                    monthLabel: this.formatMonth(p.year, p.month),
                    amountDisplay: this.formatCurrency(p.total),
                    amountClass: isZero ? 'slds-text-color_error slds-text-title_bold' : ''
                };
            });

            // If all months are zero → treat as "no data"
            const anyNonZero = tableRows.some(r => !r.amountClass);
            if (!anyNonZero) {
                this.toast('No Data', 'No sales found for the selected sales rep.', 'warning');
                this.rows = [];
                return;
            }

            this.rows = tableRows;
        } catch (e) {
            this.queriedOnce = true; // so we can show inline error state if desired
            this.toast('Error', this.errMsg(e, 'Failed to load data.'), 'error');
        }
    }

    // --- helpers ---
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
