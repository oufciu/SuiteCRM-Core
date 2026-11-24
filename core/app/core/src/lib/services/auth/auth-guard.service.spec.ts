/**
 * SuiteCRM is a customer relationship management program developed by SuiteCRM Ltd.
 * Copyright (C) 2021 SuiteCRM Ltd.
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License version 3 as published by the
 * Free Software Foundation with the addition of the following permission added
 * to Section 15 as permitted in Section 7(a): FOR ANY PART OF THE COVERED WORK
 * IN WHICH THE COPYRIGHT IS OWNED BY SUITECRM, SUITECRM DISCLAIMS THE
 * WARRANTY OF NON INFRINGEMENT OF THIRD PARTY RIGHTS.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * In accordance with Section 7(b) of the GNU Affero General Public License
 * version 3, these Appropriate Legal Notices must retain the display of the
 * "Supercharged by SuiteCRM" logo. If the display of the logos is not reasonably
 * feasible for technical reasons, the Appropriate Legal Notices must display
 * the words "Supercharged by SuiteCRM".
 */

import {ActivatedRouteSnapshot, DefaultUrlSerializer, Router, RouterStateSnapshot, UrlTree} from '@angular/router';
import {Observable, Subject} from 'rxjs';
import {AuthGuard} from './auth-guard.service';
import {AuthService} from './auth.service';
import {AppStateStore} from '../../store/app-state/app-state.store';
import {RouteConverter} from '../navigation/route-converter/route-converter.service';
import {AsyncActionService} from '../process/processes/async-action/async-action';
import {Process} from '../process/process.service';

describe('AuthGuard', () => {
    let guard: AuthGuard;
    let session: Subject<boolean | UrlTree>;
    let actions: jasmine.SpyObj<AsyncActionService>;
    let acl: Subject<Process>;
    let results: (boolean | UrlTree)[];
    const serializer = new DefaultUrlSerializer();
    const snapshot = {url: '/accounts/record/test-id'} as RouterStateSnapshot;
    const route = new ActivatedRouteSnapshot();
    const aclResult = (result: boolean): Process => ({
        id: 'user-acl',
        _id: 'user-acl',
        status: 'success',
        async: false,
        type: 'user-acl',
        options: {},
        data: {result},
        messages: []
    });

    beforeEach(() => {
        session = new Subject();
        acl = new Subject();
        actions = jasmine.createSpyObj<AsyncActionService>('AsyncActionService', ['run']);
        actions.run.and.returnValue(acl.asObservable());
        results = [];
        const auth = jasmine.createSpyObj<AuthService>('AuthService', ['authorizeUserSession']);
        auth.authorizeUserSession.and.returnValue(session.asObservable());
        const routes = jasmine.createSpyObj<RouteConverter>('RouteConverter', ['parseRouteURL']);
        routes.parseRouteURL.and.returnValue({module: 'accounts', action: 'record', record: 'test-id'});

        guard = new AuthGuard(
            {parseUrl: (url: string) => serializer.parse(url)} as Router,
            auth,
            actions,
            {getRouteUrl: () => '', getLoginWizardComplete: () => true} as AppStateStore,
            routes,
            null,
            null
        );

        (guard.canActivate(route, snapshot) as Observable<boolean | UrlTree>).subscribe(value => results.push(value));
    });

    it('redirects a logged-out record deep link without starting a protected ACL request', () => {
        const login = serializer.parse('/Login');
        session.next(login);
        session.complete();
        acl.next(aclResult(true));

        expect(results).toEqual([login]);
        expect(actions.run).not.toHaveBeenCalled();
    });

    it('does not start an ACL request when session authorization denies navigation', () => {
        session.next(false);
        session.complete();
        acl.next(aclResult(true));

        expect(results).toEqual([false]);
        expect(actions.run).not.toHaveBeenCalled();
    });

    it('waits for the session before checking ACL for the requested record', () => {
        expect(actions.run).not.toHaveBeenCalled();
        expect(results).toEqual([]);

        session.next(true);
        session.complete();

        expect(actions.run).toHaveBeenCalledOnceWith('user-acl', jasmine.objectContaining({
            module: 'accounts',
            payload: jasmine.objectContaining({routeAction: 'record', record: 'test-id'})
        }));
        expect(results).toEqual([]);

        acl.next(aclResult(true));
        expect(results).toEqual([true]);
    });

    it('keeps the ACL denial redirect for an authenticated session', () => {
        session.next(true);
        session.complete();
        acl.next(aclResult(false));

        expect(results.map(result => result instanceof UrlTree ? serializer.serialize(result) : result)).toEqual(['/']);
    });
});
